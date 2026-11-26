# =========================================================================
# run_app.R -- запуск интерактивной карты слов
# Перед первым запуском: Rscript install_packages.R  и  Rscript run_pipeline.R
# Запуск: Rscript run_app.R   (либо открыть app.R в RStudio и нажать Run App)
# =========================================================================
shiny::runApp(".", launch.browser = TRUE)
