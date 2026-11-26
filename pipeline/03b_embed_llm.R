# =========================================================================
# 03b_embed_llm.R -- локальные LLM-эмбеддинги вместо word2vec
# Эмбеддит: (1) высказывания целиком (text_raw), (2) леммы словаря карты.
# Всё одной моделью -> слова и высказывания в одном векторном пространстве,
# поэтому механика тегов (центроид слов vs вектора высказываний) не меняется.
# Требует: Python 3 + пакеты sentence-transformers, pandas (pip install).
# =========================================================================
library(dplyr)
library(readr)

source("pipeline/00_config.R")

prep <- readRDS(RDS_PREP)
df <- prep$df

# --- проверка Python-окружения --------------------------------------------
py_check <- suppressWarnings(system2(
  PYTHON_BIN, c("-c", shQuote("import sentence_transformers, pandas")),
  stdout = TRUE, stderr = TRUE
))
if (!is.null(attr(py_check, "status")) && attr(py_check, "status") != 0) {
  stop("Python-окружение не готово. Установите зависимости:\n  ",
       PYTHON_BIN, " -m pip install sentence-transformers pandas\n",
       "Вывод проверки: ", paste(py_check, collapse = "\n"))
}

# --- словарь карты: леммы с частотой >= MIN_WORD_FREQ_ON_MAP ---------------
word_freq <- prep$tokens %>% count(lemma, name = "freq", sort = TRUE)
vocab <- word_freq %>% filter(freq >= MIN_WORD_FREQ_ON_MAP) %>% pull(lemma)
message("Лемм для эмбеддинга (freq >= ", MIN_WORD_FREQ_ON_MAP, "): ", length(vocab))
message("Высказываний для эмбеддинга: ", nrow(df))

# --- обмен с Python через временные CSV ------------------------------------
stmt_in  <- file.path(DATA_DIR, "llm_tmp_stmt_in.csv")
stmt_out <- file.path(DATA_DIR, "llm_tmp_stmt_out.csv")
word_in  <- file.path(DATA_DIR, "llm_tmp_word_in.csv")
word_out <- file.path(DATA_DIR, "llm_tmp_word_out.csv")

write_csv(tibble(id = df$stmt_id, text = df$text_raw), stmt_in)
write_csv(tibble(id = vocab, text = vocab), word_in)

run_embed <- function(in_csv, out_csv, what) {
  message("Эмбеддинг: ", what, "...")
  status <- system2(PYTHON_BIN,
                    c("pipeline/embed_local.py", LLM_EMB_MODEL, in_csv, out_csv))
  if (status != 0) stop("Python-скрипт эмбеддинга завершился с ошибкой (", what, ").")
}

run_embed(stmt_in, stmt_out, "высказывания")
run_embed(word_in, word_out, "слова")

# --- сборка матриц ----------------------------------------------------------
stmt_df <- read_csv(stmt_out, show_col_types = FALSE)
stmt_vecs <- as.matrix(stmt_df[, -1])
rownames(stmt_vecs) <- as.character(stmt_df$id)

word_df <- read_csv(word_out, show_col_types = FALSE)
emb_words <- as.matrix(word_df[, -1])
rownames(emb_words) <- word_df$id

message("Вектора высказываний: ", nrow(stmt_vecs), " x ", ncol(stmt_vecs))
message("Вектора слов: ", nrow(emb_words), " x ", ncol(emb_words))

saveRDS(list(emb_words = emb_words, stmt_vecs = stmt_vecs, model = LLM_EMB_MODEL),
        LLM_EMB_RDS)
file.remove(stmt_in, stmt_out, word_in, word_out)
message("Сохранено в ", LLM_EMB_RDS)
