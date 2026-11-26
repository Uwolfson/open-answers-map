# Самостоятельная разбивка высказываний на теги, максимально отражающая сегменты.
# Мелкие смысловые скопления (k-means по векторам) склеиваются снизу вверх:
# стоимость склейки = смысловое расстояние (Ward) + MAP_LAMBDA * потеря информации о сегменте (IB),
# склеивать можно только смысловых соседей. Уровни иерархии = теги / подтеги / мелкие скопления.
# Запуск из корня проекта: Rscript map/01_cluster.R
source("pipeline/00_config.R")
K_FINE <- MAP_K_FINE; K_MID <- MAP_K_MID; K_TOP <- MAP_K_TOP; NEIGH <- 8
LAMBDA <- MAP_LAMBDA; W_SEG <- MAP_W_SEG
d <- readRDS(RDS_APP_DATA); df <- d$df
stopifnot(SEGMENT_VAR %in% names(df))
seg_raw <- as.character(df[[SEGMENT_VAR]])
valid <- which(!is.na(df$lemma_text) & !is.na(seg_raw) & seg_raw != "")
X <- d$stmt_vecs[valid,]; X <- X/sqrt(rowSums(X^2))
# сегменты по порядку: факторы -- как в подписях, числа -- по значению
lev <- if (is.factor(df[[SEGMENT_VAR]])) intersect(levels(df[[SEGMENT_VAR]]), seg_raw[valid]) else as.character(sort(unique(df[[SEGMENT_VAR]][valid])))
seg <- match(seg_raw[valid], lev); S <- length(lev); N <- length(seg)
pc <- prcomp(X, rank.=min(50, ncol(X), nrow(X)-1)); Z <- pc$x
# вероятности сегментов, предсказанные по тексту (5-кратная кросс-валидация, multinom на 30 ГК)
set.seed(5); fold <- sample(rep(1:5, length.out=nrow(Z))); P <- matrix(0, nrow(Z), S)
pcs <- seq_len(min(30, ncol(Z)))
for (f in 1:5) { m <- nnet::multinom(factor(seg[fold!=f], levels=1:S) ~ ., data=data.frame(Z[fold!=f,pcs]), trace=FALSE, decay=5, maxit=300, MaxNWts=50000)
  P[fold==f,] <- predict(m, data.frame(Z[fold==f,pcs]), type="probs") }
acc <- mean(max.col(P)==seg)
ZF <- cbind(Z, W_SEG*sqrt(sum(apply(Z,2,var)))*scale(P,scale=FALSE)/sqrt(sum(apply(P,2,var))))
set.seed(11); km <- kmeans(ZF, K_FINE, nstart=8, iter.max=200)
fine <- km$cluster
cnt <- t(sapply(1:K_FINE, function(c) tabulate(seg[fine==c], S)))
mu <- km$centers[,seq_len(ncol(Z))]; nn <- rowSums(cnt)
kl <- function(p,q){ i <- p>0; sum(p[i]*log(p[i]/q[i])) }
ib_cost <- function(a,b){ ca<-cnt[a,];cb<-cnt[b,]; pa<-ca/sum(ca); pb<-cb/sum(cb); pab<-(ca+cb)/sum(ca+cb)
  (sum(ca)*kl(pa,pab)+sum(cb)*kl(pb,pab))/N }
ward <- function(a,b) nn[a]*nn[b]/(nn[a]+nn[b])*sum((mu[a,]-mu[b,])^2)/N
alive <- 1:K_FINE; snap <- list()
# нормировки по начальным кандидатам
cand <- t(combn(1:K_FINE,2))
w0 <- median(apply(cand[sample(nrow(cand),min(2000,nrow(cand))),],1,function(r) ward(r[1],r[2])))
i0 <- median(apply(cand[sample(nrow(cand),min(2000,nrow(cand))),],1,function(r) ib_cost(r[1],r[2])))
memb <- as.list(1:K_FINE)
while (length(alive) > K_TOP) {
  M <- mu[alive,,drop=FALSE]; D2 <- as.matrix(dist(M))
  best <- Inf; ba <- bb <- NA
  for (ii in seq_along(alive)) { nb <- order(D2[ii,])[2:min(NEIGH+1,length(alive))]
    for (jj in nb) { a<-alive[ii]; b<-alive[jj]; if (a>b) next
      cst <- ward(a,b)/w0 + LAMBDA*ib_cost(a,b)/i0
      if (cst<best){best<-cst;ba<-a;bb<-b} } }
  # склейка bb в ba
  mu[ba,] <- (nn[ba]*mu[ba,]+nn[bb]*mu[bb,])/(nn[ba]+nn[bb]); nn[ba] <- nn[ba]+nn[bb]
  cnt[ba,] <- cnt[ba,]+cnt[bb,]; memb[[ba]] <- c(memb[[ba]],memb[[bb]]); alive <- setdiff(alive,bb)
  if (length(alive)==K_MID) snap$mid <- lapply(alive, function(a) memb[[a]])
}
snap$top <- lapply(alive, function(a) memb[[a]])
assign_lvl <- function(groups){ a <- integer(K_FINE); for(g in seq_along(groups)) a[groups[[g]]] <- g; a[fine] }
top <- assign_lvl(snap$top); mid <- assign_lvl(snap$mid)
cramer <- function(a,b){ tb <- table(a,b); x <- suppressWarnings(chisq.test(tb,correct=FALSE)$statistic); unname(sqrt(x/(sum(tb)*(min(dim(tb))-1)))) }
perm <- function(a,b,R=30){ set.seed(1); mean(replicate(R, cramer(a, sample(b)))) }
set.seed(3); base <- kmeans(Z, K_TOP, nstart=10)$cluster
res <- c(lambda=LAMBDA, w=W_SEG, acc=acc, majority=max(tabulate(seg,S))/N, V_seg=cramer(top,seg), V_perm=perm(top,seg),
         V_base=cramer(base,seg), V_mid=cramer(mid,seg), V_fine=cramer(fine,seg),
         within_top=sum(sapply(1:K_TOP,function(g) sum(scale(Z[top==g,],scale=FALSE)^2)))/sum(scale(Z,scale=FALSE)^2),
         within_base=sum(sapply(1:K_TOP,function(g) sum(scale(Z[base==g,],scale=FALSE)^2)))/sum(scale(Z,scale=FALSE)^2),
         minsize=min(table(top)), maxsize=max(table(top)))
print(round(res,3))
dir.create(MAP_OUT_DIR, showWarnings=FALSE, recursive=TRUE)
saveRDS(list(top=top, mid=mid, fine=fine, valid=valid, seg=seg, lev=lev, res=res, Z=Z, X=X), file.path(MAP_OUT_DIR, "clusters.rds"))
