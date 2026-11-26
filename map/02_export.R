# Экспорт разбивки (01_cluster.R) для страницы карты + сводка для названий тегов.
# Запуск из корня проекта: Rscript map/02_export.R
# Результаты (map/out) содержат ответы респондентов -- в репозиторий они не попадают.
suppressMessages({library(jsonlite)})
source("pipeline/00_config.R")
A <- readRDS(file.path(MAP_OUT_DIR, "clusters.rds")); df <- readRDS(RDS_APP_DATA)$df
v <- A$valid; X <- A$X; seg <- A$seg; S <- length(A$lev); N <- length(v)
perp <- min(40, floor((N-1)/3))
# раскладка: t-SNE по ГК + one-hot подтегов (0.3) и тегов (0.55), чтобы теги стали областями карты
Zn <- A$Z/sqrt(sum(apply(A$Z,2,var))); oh <- function(x){ m <- matrix(0,length(x),max(x)); m[cbind(seq_along(x),x)] <- 1; m }
F <- cbind(Zn, .3*oh(A$mid), .55*oh(A$top))
key <- apply(round(F[,1:20],6),1,paste,collapse="|"); u <- !duplicated(key)
set.seed(42); ts <- Rtsne::Rtsne(F[u,], perplexity=perp, check_duplicates=FALSE, pca=FALSE, verbose=FALSE)$Y
xy <- ts[match(key,key[u]),]
toks <- lapply(strsplit(df$lemma_text[v]," "), unique); alltab <- table(unlist(toks))
words <- function(ix, top=6){ n1<-length(ix); tin<-table(unlist(toks[ix])); w<-names(tin)[tin>=max(3,0.08*n1)]
  if(!length(w)) return(character(0)); a<-as.numeric(tin[w]); b<-as.numeric(alltab[w])-a
  lo<-log((a+.5)/(n1-a+.5))-log((b+.5)/(N-n1-b+.5)); o<-order(-lo)[1:min(top,length(w))]; w[o] }
segtot <- tabulate(seg,S)
desc <- function(lab){ K <- max(lab); lapply(1:K, function(g){ ix <- which(lab==g)
  c0 <- colMeans(X[ix,,drop=FALSE]); sim <- as.numeric(X[ix,,drop=FALSE]%*%c0); o <- ix[order(-sim)]
  tx <- df$text_raw[v][o]; ok <- o[nchar(tx)>=25 & !duplicated(tolower(tx))]
  idx <- round(100*(tabulate(seg[ix],S)/length(ix))/(segtot/N))
  list(n=length(ix), x=round(mean(xy[ix,1]),2), y=round(mean(xy[ix,2]),2), words=words(ix), seg=idx,
       ex=df$text_raw[v][head(ok,6)]) }) }
lv <- list(top=desc(A$top), mid=desc(A$mid), fine=desc(A$fine))
par_mid <- sapply(1:max(A$mid), function(m) as.integer(names(which.max(table(A$top[A$mid==m])))))
par_fine <- sapply(1:max(A$fine), function(f) A$mid[A$fine==f][1])
# вторая раскладка: t-SNE по аффинити к сегментам = косинус вектора высказывания к центроиду каждого
# сегмента (свой сегмент -- без самого высказывания), центрировано по строке, z по столбцу
sums <- t(sapply(1:S, function(k) colSums(X[seg==k,,drop=FALSE])))
aff <- sapply(1:S, function(k){ cen <- matrix(sums[k,], nrow(X), ncol(X), byrow=TRUE); own <- seg==k
  cen[own,] <- cen[own,] - X[own,]; cen <- cen/ifelse(own, segtot[k]-1, segtot[k])
  rowSums(X*cen)/sqrt(rowSums(cen^2)) })
aff <- aff - rowMeans(aff); aff <- scale(aff)
aff_acc <- mean(max.col(aff)==seg)
key2 <- apply(round(aff,6),1,paste,collapse="|"); u2 <- !duplicated(key2)
set.seed(42); ts2 <- Rtsne::Rtsne(aff[u2,], perplexity=perp, check_duplicates=FALSE, pca=FALSE, verbose=FALSE)$Y
xy2 <- ts2[match(key2,key2[u2]),]
cat("affinity argmax = own segment:", round(aff_acc,3), "\n")
pts <- data.frame(x=round(xy[,1],2), y=round(xy[,2],2), x2=round(xy2[,1],2), y2=round(xy2[,2],2), am=max.col(aff),
                  t=df$text_raw[v], s=seg, a=A$top-1L, b=A$mid-1L, c=A$fine-1L)
# названия тегов (необязательно): map/out/names.json = {"top": [...], "mid": [...]}; иначе подписи из общих слов
names_file <- file.path(MAP_OUT_DIR, "names.json")
nm <- if (file.exists(names_file)) fromJSON(names_file) else list(top=character(0), mid=character(0))
write(toJSON(list(pts=pts, top=lv$top, mid=lv$mid, fine=lv$fine, parMid=par_mid-1L, parFine=par_fine-1L,
  segTot=segtot, segLabels=A$lev, names=nm, res=as.list(round(c(A$res, aff_acc=aff_acc),3))), dataframe="rows", auto_unbox=TRUE),
  file.path(MAP_OUT_DIR, "data.json"))
# сводка для названий: номер строки в names.json = номер TOP / MID
sink(file.path(MAP_OUT_DIR, "summary.txt"))
for (g in seq_along(lv$top)) { t <- lv$top[[g]]
  cat(sprintf("\n=== TOP %d  n=%d  words: %s\n   seg idx: %s\n", g, t$n, paste(t$words,collapse=", "), paste(t$seg,collapse=" ")))
  for (e in head(t$ex,4)) cat("   ex:", substr(e,1,140), "\n")
  for (m in which(par_mid==g)) { mm <- lv$mid[[m]]
    cat(sprintf("  -- MID %d n=%d words: %s | seg: %s\n", m, mm$n, paste(mm$words,collapse=", "), paste(mm$seg,collapse=" ")))
    for (e in head(mm$ex,2)) cat("       ex:", substr(e,1,120), "\n") } }
sink()
cat("ok\n")
