# =========================================================================
# install_packages.R -- установка всех R-пакетов, нужных проекту
# Запуск один раз:  Rscript install_packages.R
# =========================================================================
required <- c(
  "haven",    # чтение .sav (SPSS)
  "dplyr", "stringr", "tidyr",   # обработка данных
  "udpipe",   # токенизация + лемматизация (модель для русского скачается автоматически)
  "stopwords",# стоп-слова
  "word2vec", # обучение word2vec (без Python/gensim, чистый R/C++)
  "Rtsne",    # t-SNE проекция
  "shiny", "plotly", "DT", "readr", # интерактивное приложение
  "jsonlite", "nnet" # карта автотегов (map/)
)

missing <- required[!sapply(required, requireNamespace, quietly = TRUE)]
if (length(missing) > 0) {
  message("Устанавливаю пакеты: ", paste(missing, collapse = ", "))
  install.packages(missing, repos = "https://cloud.r-project.org")
} else {
  message("Все нужные пакеты уже установлены.")
}
