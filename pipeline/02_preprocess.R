# =========================================================================
# 02_preprocess.R -- очистка, токенизация и лемматизация высказываний
# =========================================================================
library(dplyr)
library(stringr)
library(udpipe)
library(stopwords)

source("pipeline/00_config.R")

df <- readRDS(RDS_RAW)

# --- 1. Базовая очистка текста -------------------------------------------
clean_text <- function(x) {
  x <- tolower(x)
  if (NORMALIZE_YO) x <- str_replace_all(x, "ё", "е")  # ё -> е
  x <- str_replace_all(x, "[^а-яa-z0-9\\s-]", " ")               # убираем пунктуацию
  x <- str_squish(x)
  x
}
df$text_clean <- clean_text(df$text_raw)

# --- 2. Лемматизация через udpipe ----------------------------------------
dir.create("data/udpipe_model", showWarnings = FALSE, recursive = TRUE)
model_path <- list.files("data/udpipe_model", pattern = "\\.udpipe$", full.names = TRUE)[1]
if (is.na(model_path)) {
  message("Модель udpipe для русского языка не найдена -- скачиваю (нужен интернет, ~44 МБ)...")
  dl <- udpipe_download_model(language = "russian-syntagrus", model_dir = "data/udpipe_model")
  if (isTRUE(dl$download_failed)) {
    stop("Не удалось скачать модель udpipe. Проверьте интернет-соединение и повторите запуск.")
  }
  model_path <- dl$file_model
}
ud_model <- udpipe_load_model(model_path)

message("Лемматизирую ", nrow(df), " высказываний... (может занять пару минут)")
ann <- udpipe_annotate(
  ud_model,
  x = df$text_clean,
  doc_id = df$stmt_id,
  tagger = "default",
  parser = "none"        # синтаксический разбор не нужен, так быстрее
) %>% as.data.frame(detailed = FALSE)

# --- 2.5. Частица "не" объединяется со следующим значимым словом ----------
# "не нужно тащить" -> леммы "не_нужно", "тащить". Иначе отрицание теряется
# (частицы отфильтровываются по upos, и смысл высказывания инвертируется).
ann <- ann %>%
  group_by(doc_id, sentence_id) %>%
  mutate(lemma = ifelse(
    !is.na(lag(lemma)) & tolower(lag(lemma)) == "не" &
      upos %in% c("NOUN", "VERB", "ADJ", "ADV", "PROPN"),
    paste0("не_", lemma), lemma
  )) %>%
  ungroup()

# стоп-слова: пакет stopwords + немного специфичных для опросов
ru_stop <- stopwords("ru", source = "snowball")
survey_stop <- c("это", "весь", "который", "свой", "просто", "очень", "просто")
stop_all <- unique(c(ru_stop, survey_stop))

tokens <- ann %>%
  filter(!is.na(lemma), nchar(lemma) >= MIN_TOKEN_LEN, upos %in% c("NOUN","VERB","ADJ","ADV","PROPN")) %>%
  mutate(lemma = tolower(lemma)) %>%
  filter(!lemma %in% stop_all) %>%
  transmute(stmt_id = as.integer(doc_id), token = token, lemma = lemma, upos = upos)

# Леммы обратно в df (одна строка на высказывание с вектором лемм)
lemma_by_stmt <- tokens %>%
  group_by(stmt_id) %>%
  summarise(lemmas = list(lemma), lemma_text = paste(lemma, collapse = " "), .groups = "drop")

df2 <- df %>%
  left_join(lemma_by_stmt, by = "stmt_id")

n_empty <- sum(sapply(df2$lemmas, function(x) length(x) == 0 || is.null(x)))
message("Высказываний без ни одной значимой леммы (после чистки/стоп-слов): ", n_empty, " из ", nrow(df2))

saveRDS(list(df = df2, tokens = tokens), RDS_PREP)
message("Сохранено в ", RDS_PREP)

# Немного примеров для проверки качества лемматизации
message("\nПримеры (исходный текст -> леммы):")
set.seed(1)
idx <- sample(which(lengths(df2$lemmas) > 0), min(10, nrow(df2)))
for (i in idx) {
  cat(sprintf(" - \"%s\" -> [%s]\n", df2$text_raw[i], paste(df2$lemmas[[i]], collapse = ", ")))
}
