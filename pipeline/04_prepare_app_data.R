# =========================================================================
# 04_prepare_app_data.R -- t-SNE, векторы высказываний, характерные примеры
# =========================================================================
library(dplyr)
library(word2vec)
library(Rtsne)
library(stringr)

source("pipeline/00_config.R")

prep <- readRDS(RDS_PREP)
df   <- prep$df

if (EMBEDDING_SOURCE == "llm") {
  message("Источник векторов: LLM-эмбеддинги (", LLM_EMB_RDS, ")")
  llm <- readRDS(LLM_EMB_RDS)
  emb <- llm$emb_words
} else {
  message("Источник векторов: word2vec (", W2V_MODEL_PATH, ")")
  model <- read.word2vec(W2V_MODEL_PATH)
  emb <- as.matrix(model)
  emb <- emb[!rownames(emb) %in% c("</s>"), , drop = FALSE]
}

# --- частоты слов в корпусе (для фильтра и размера точки на карте) -------
word_freq <- prep$tokens %>%
  filter(lemma %in% rownames(emb)) %>%
  count(lemma, name = "freq", sort = TRUE)

vocab <- word_freq %>% filter(freq >= MIN_WORD_FREQ_ON_MAP) %>% pull(lemma)
vocab <- intersect(vocab, rownames(emb))
message("Слов на карте (freq >= ", MIN_WORD_FREQ_ON_MAP, "): ", length(vocab))

emb_map <- emb[vocab, , drop = FALSE]

# --- t-SNE -----------------------------------------------------------------
set.seed(TSNE_SEED)
perpl <- min(TSNE_PERPLEXITY, floor((nrow(emb_map) - 1) / 3))
message("t-SNE perplexity = ", perpl, " (слов: ", nrow(emb_map), ")")
tsne <- Rtsne(emb_map, dims = 2, perplexity = perpl, check_duplicates = FALSE, pca = TRUE)

word_coords <- tibble(
  word = vocab,
  x = tsne$Y[, 1],
  y = tsne$Y[, 2],
  freq = word_freq$freq[match(vocab, word_freq$lemma)]
)

# --- Векторы высказываний ---------------------------------------------------
# word2vec: среднее векторов лемм высказывания.
# llm: высказывание эмбеддится целиком (уже посчитано в 03b) -- учитывает
#      порядок слов, отрицания и синтаксис.
if (EMBEDDING_SOURCE == "llm") {
  stmt_vecs <- llm$stmt_vecs[as.character(df$stmt_id), , drop = FALSE]
} else {
  lemma_list <- setNames(df$lemmas, df$stmt_id)
  sentence_vec <- function(lemmas) {
    lemmas <- lemmas[lemmas %in% rownames(emb)]
    if (length(lemmas) == 0) return(rep(NA_real_, ncol(emb)))
    colMeans(emb[lemmas, , drop = FALSE])
  }
  stmt_vecs <- t(sapply(lemma_list, sentence_vec))
  rownames(stmt_vecs) <- names(lemma_list)
}
valid_stmt <- rownames(stmt_vecs)[!is.na(stmt_vecs[, 1])]

cosine_sim_vec_to_matrix <- function(v, M) {
  denom <- sqrt(sum(v^2)) * sqrt(rowSums(M^2))
  denom[denom == 0] <- NA
  as.numeric((M %*% v) / denom)
}

# --- Для каждого слова: индексы высказываний, где оно встречается,
#     и топ-N высказываний по близости усреднённого вектора высказывания
#     к вектору слова (embedding-based "характерность") -------------------
message("Считаю индекс слово -> высказывания и топ-", TOP_N_CHARACTERISTIC, " характерных...")

word_to_stmt_ids <- lapply(vocab, function(w) {
  df$stmt_id[sapply(df$lemmas, function(ls) w %in% ls)]
})
names(word_to_stmt_ids) <- vocab

word_top_examples <- lapply(vocab, function(w) {
  ids <- as.character(word_to_stmt_ids[[w]])
  ids <- intersect(ids, valid_stmt)
  if (length(ids) == 0) return(tibble(stmt_id = integer(0), text = character(0), similarity = numeric(0)))
  M <- stmt_vecs[ids, , drop = FALSE]
  sims <- cosine_sim_vec_to_matrix(emb[w, ], M)
  ord <- order(sims, decreasing = TRUE)
  top_ids <- as.integer(ids[ord][seq_len(min(TOP_N_CHARACTERISTIC, length(ord)))])
  tibble(
    stmt_id = top_ids,
    text = df$text_raw[match(top_ids, df$stmt_id)],
    similarity = sims[ord][seq_len(min(TOP_N_CHARACTERISTIC, length(ord)))]
  )
})
names(word_top_examples) <- vocab

app_data <- list(
  df = df,                          # исходные высказывания + леммы
  emb = emb,                        # все векторы слов
  stmt_vecs = stmt_vecs,            # векторы высказываний (по stmt_id как rownames)
  word_coords = word_coords,        # координаты слов на карте (t-SNE)
  word_to_stmt_ids = word_to_stmt_ids,
  word_top_examples = word_top_examples,
  vocab = vocab
)

saveRDS(app_data, RDS_APP_DATA)
message("Сохранено в ", RDS_APP_DATA)

# --- Небольшая проверка -----------------------------------------------------
message("\nПример топ-", TOP_N_CHARACTERISTIC, " высказываний для нескольких слов:")
for (w in intersect(c("цена","качество","быстро"), vocab)) {
  cat("\n===", w, "===\n")
  ex <- word_top_examples[[w]]
  for (i in seq_len(nrow(ex))) cat(sprintf("  [%.2f] %s\n", ex$similarity[i], ex$text[i]))
}
