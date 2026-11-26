# =========================================================================
# 03_train_word2vec.R -- обучение word2vec на лемматизированном корпусе
# =========================================================================
library(dplyr)
library(word2vec)

source("pipeline/00_config.R")

prep <- readRDS(RDS_PREP)
df <- prep$df

corpus <- df$lemma_text[nchar(df$lemma_text) > 0 & !is.na(df$lemma_text)]
message("Высказываний в корпусе для word2vec: ", length(corpus))

set.seed(42)
model <- word2vec(
  x = corpus,
  type = W2V_TYPE,
  dim = W2V_DIM,
  window = W2V_WINDOW,
  iter = W2V_ITER,
  min_count = W2V_MIN_COUNT,
  negative = W2V_NEGATIVE,
  threads = max(1, parallel::detectCores() - 1)
)

write.word2vec(model, W2V_MODEL_PATH)
message("Модель word2vec сохранена в ", W2V_MODEL_PATH)

emb <- as.matrix(model)
emb <- emb[!rownames(emb) %in% c("</s>"), , drop = FALSE]
message("Слов в словаре модели: ", nrow(emb), ", размерность: ", ncol(emb))

# Быстрая проверка адекватности векторов -- ближайшие соседи для нескольких частотных слов
check_words <- intersect(c("цена", "качество", "быстро", "удобно", "сервис"), rownames(emb))
for (w in check_words) {
  nn <- predict(model, w, type = "nearest", top_n = 6)[[1]]
  cat(sprintf("\nБлижайшие к '%s':\n", w))
  print(nn)
}
