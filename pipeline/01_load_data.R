# =========================================================================
# 01_load_data.R -- читает .sav, достаёт высказывания, присваивает id
# =========================================================================
library(haven)
library(dplyr)

source("pipeline/00_config.R")

message("Читаю файл: ", RAW_SAV_PATH)
raw <- read_sav(RAW_SAV_PATH)

stopifnot(TEXT_VAR %in% names(raw))

df <- raw %>%
  mutate(stmt_id = row_number()) %>%
  rename(text_raw = !!TEXT_VAR) %>%
  filter(!is.na(text_raw), trimws(text_raw) != "") %>%
  select(stmt_id, text_raw, everything())

# Аккуратно превращаем labelled-столбцы в читаемые факторы (если есть) --
# пригодится для фильтров в приложении (сегмент, частота покупки и т.д.)
for (nm in names(df)) {
  if (inherits(df[[nm]], "haven_labelled")) {
    df[[nm]] <- as_factor(df[[nm]])
  }
}

message("Строк с непустым текстом: ", nrow(df), " из ", nrow(raw))
message("Столбцы: ", paste(names(df), collapse = ", "))

dir.create(DATA_DIR, showWarnings = FALSE, recursive = TRUE)
saveRDS(df, RDS_RAW)
message("Сохранено в ", RDS_RAW)
