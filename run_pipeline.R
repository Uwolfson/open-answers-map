# =========================================================================
# run_pipeline.R -- полный прогон: данные -> предобработка -> вектора -> app_data
# Источник векторов задаётся в pipeline/00_config.R (EMBEDDING_SOURCE):
#   "word2vec" -- обучение word2vec на корпусе (шаг 03)
#   "llm"      -- локальные LLM-эмбеддинги, нужен Python (шаг 03b)
# ВАЖНО: запускать из корня проекта:
#   cd word2vec_project
#   Rscript run_pipeline.R
# =========================================================================
source("pipeline/01_load_data.R")
source("pipeline/02_preprocess.R")

source("pipeline/00_config.R")
if (EMBEDDING_SOURCE == "llm") {
  source("pipeline/03b_embed_llm.R")
} else {
  source("pipeline/03_train_word2vec.R")
}

source("pipeline/04_prepare_app_data.R")

message("\nГотово! Запускайте приложение: shiny::runApp('.')  либо  Rscript run_app.R")
