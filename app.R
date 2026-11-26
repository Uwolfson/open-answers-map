# =========================================================================
# app.R -- интерактивная карта слов
#   - наведение (hover)  -> 5 самых характерных высказываний со словом
#   - клик по слову       -> модальное окно со ВСЕМИ высказываниями со словом
#   - лассо-выделение слов + название -> создание тега, сохранение в базу
#   - "Перестроить по тегам" -> t-SNE по близостям слов к тегам (с якорем
#     на текущие координаты, чтобы слова не разлетались) + раскраска
# Запуск:  shiny::runApp(".")   либо   Rscript run_app.R
# =========================================================================
library(shiny)
library(plotly)
library(DT)
library(dplyr)
library(readr)
library(stringr)
library(Rtsne)

source("pipeline/00_config.R")

# --------------------------------------------------------------------------
# Загрузка подготовленных данных (см. run_pipeline.R / pipeline/01-04_*.R)
# --------------------------------------------------------------------------
if (!file.exists(RDS_APP_DATA)) {
  stop("Не найден ", RDS_APP_DATA, ". Сначала запустите run_pipeline.R (или скрипты R/01_..-04_.. по очереди).")
}
app_data <- readRDS(RDS_APP_DATA)

df               <- app_data$df
emb              <- app_data$emb
stmt_vecs        <- app_data$stmt_vecs
word_coords      <- app_data$word_coords
word_to_stmt_ids <- app_data$word_to_stmt_ids
word_top_examples<- app_data$word_top_examples
vocab            <- app_data$vocab

valid_stmt_ids <- rownames(stmt_vecs)[!is.na(stmt_vecs[, 1])]
stmt_vecs_valid <- stmt_vecs[valid_stmt_ids, , drop = FALSE]

cosine_sim_vec_to_matrix <- function(v, M) {
  denom <- sqrt(sum(v^2)) * sqrt(rowSums(M^2))
  denom[denom == 0] <- NA
  as.numeric((M %*% v) / denom)
}

DEFAULT_WORD_COLOR <- "#4C78A8"
TAG_PALETTE <- c("#e15759", "#59a14f", "#f28e2b", "#b07aa1", "#76b7b2",
                 "#ff9da7", "#9c755f", "#edc948", "#af7aa1", "#bab0ac")

# --------------------------------------------------------------------------
# Подготовка hover-текста (топ-N характерных высказываний на слово)
# --------------------------------------------------------------------------
make_hover <- function(w) {
  ex <- word_top_examples[[w]]
  if (is.null(ex) || nrow(ex) == 0) return(paste0("<b>", w, "</b><br>(нет примеров)"))
  lines <- sprintf("%s. %s", seq_len(nrow(ex)), str_trunc(ex$text, 70))
  paste0("<b>", w, "</b> (n=", length(word_to_stmt_ids[[w]]), ")<br>",
         paste(lines, collapse = "<br>"))
}
word_coords$hovertext <- vapply(word_coords$word, make_hover, character(1))
word_meta <- word_coords %>% select(word, freq, hovertext)

# --------------------------------------------------------------------------
# Персистентность тегов
# --------------------------------------------------------------------------
ensure_data_dir <- function() dir.create(DATA_DIR, showWarnings = FALSE, recursive = TRUE)

load_tags_log <- function() {
  if (file.exists(TAGS_LOG_CSV)) {
    # ВАЖНО: типы столбцов заданы явно. Если довериться автоопределению readr,
    # столбец created_at на повторном чтении иногда распознаётся как datetime
    # (а не character), и тогда bind_rows() с новой строкой падает с ошибкой
    # несовместимых типов. Проверено на практике при создании второго тега подряд.
    read_csv(TAGS_LOG_CSV, show_col_types = FALSE, col_types = cols(
      tag = col_character(), words = col_character(),
      threshold = col_double(), n_statements = col_integer(),
      created_at = col_character()
    ))
  } else {
    tibble(tag = character(), words = character(), threshold = numeric(),
           n_statements = integer(), created_at = character())
  }
}

load_statement_tags <- function() {
  if (file.exists(STATEMENT_TAGS_CSV)) {
    read_csv(STATEMENT_TAGS_CSV, show_col_types = FALSE, col_types = cols(
      stmt_id = col_integer(), tag = col_character(), similarity = col_double()
    ))
  } else {
    tibble(stmt_id = integer(), tag = character(), similarity = numeric())
  }
}

load_tag_exclusions <- function() {
  if (file.exists(TAG_EXCLUSIONS_CSV)) {
    read_csv(TAG_EXCLUSIONS_CSV, show_col_types = FALSE, col_types = cols(
      tag = col_character(), stmt_id = col_integer()
    ))
  } else {
    tibble(tag = character(), stmt_id = integer())
  }
}

save_base_with_tags <- function(statement_tags) {
  tags_agg <- statement_tags %>%
    group_by(stmt_id) %>%
    summarise(tags = paste(unique(tag), collapse = " | "), .groups = "drop")
  out <- df %>%
    left_join(tags_agg, by = "stmt_id") %>%
    select(stmt_id, text_raw, tags, everything(), -lemmas, -lemma_text, -text_clean)
  write_csv(out, BASE_WITH_TAGS_CSV)
}

persist_tags <- function(tags_log, stmt_tags) {
  ensure_data_dir()
  write_csv(tags_log, TAGS_LOG_CSV)
  write_csv(stmt_tags, STATEMENT_TAGS_CSV)
  save_base_with_tags(stmt_tags)
}

append_tag <- function(tag_name, words, threshold, matched_ids, sims_named) {
  tags_log <- load_tags_log()
  stmt_tags <- load_statement_tags()

  tags_log <- bind_rows(tags_log, tibble(
    tag = tag_name,
    words = paste(words, collapse = ", "),
    threshold = threshold,
    n_statements = length(matched_ids),
    created_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  ))

  if (length(matched_ids) > 0) {
    stmt_tags <- bind_rows(stmt_tags, tibble(
      stmt_id = matched_ids,
      tag = tag_name,
      similarity = round(sims_named[as.character(matched_ids)], 4)
    ))
  }

  persist_tags(tags_log, stmt_tags)
  list(tags_log = tags_log, stmt_tags = stmt_tags)
}

# слова тега из строки "а, б, в"
split_tag_words <- function(s) trimws(strsplit(s, ",\\s*")[[1]])

# ==========================================================================
# UI
# ==========================================================================
ui <- fluidPage(
  titlePanel("Карта слов высказываний (word2vec + t-SNE)"),
  sidebarLayout(
    sidebarPanel(
      width = 3,
      h4("Создание тега"),
      helpText("Выделите слова на карте лассо (иконка лассо в панели графика), ",
               "затем задайте название и порог близости. ",
               "Двойной клик по пустому месту графика или кнопка ниже сбрасывают выделение."),
      verbatimTextOutput("selected_words_txt"),
      actionButton("reset_selection_btn", "Сбросить выделение"),
      br(), br(),
      textInput("tag_name", "Название тега", placeholder = "например: музыка"),
      sliderInput("tag_threshold", "Порог косинусной близости",
                  min = 0, max = 1, value = DEFAULT_TAG_SIMILARITY_THRESHOLD, step = 0.01),
      helpText(em(if (EMBEDDING_SOURCE == "llm") {
        "Вектора: LLM-эмбеддинги. Рабочий диапазон порога обычно 0.4-0.7. Подбирайте по предпросмотру ниже."
      } else {
        "Вектора: word2vec. На небольшом корпусе близости сжаты к 1 -- обычно нужен высокий порог (0.8-0.95). Подбирайте по предпросмотру ниже."
      })),
      verbatimTextOutput("preview_txt"),
      actionButton("create_tag_btn", "Создать тег", class = "btn-primary"),
      br(), br(),
      verbatimTextOutput("tag_status"),
      hr(),
      h4("Созданные теги"),
      helpText("Выберите тег в таблице, затем действие."),
      DTOutput("tags_table"),
      br(),
      actionButton("show_tag_stmts_btn", "Высказывания"),
      actionButton("exclude_word_btn", "Исключить слово"),
      actionButton("delete_tag_btn", "Удалить тег", class = "btn-danger"),
      hr(),
      actionButton("rebuild_btn", "Перестроить по тегам", class = "btn-info"),
      actionButton("reset_map_btn", "Исходная карта"),
      helpText("Перестроение: t-SNE по близостям слов к тегам (текущие позиции",
               "используются как стартовые, чтобы слова не разлетались).",
               sprintf("Слово красится в цвет ближайшего тега при близости > %.2f.",
                       TAG_COLOR_SIMILARITY)),
      uiOutput("tag_color_legend"),
      hr(),
      h4("Настройки карты"),
      numericInput("min_word_freq", "Мин. упоминаний слова",
                   value = MIN_WORD_FREQ_DISPLAY, min = 1, step = 1),
      numericInput("max_words", "Макс. слов на карте",
                   value = MAX_WORDS_DISPLAY, min = 100, step = 100),
      sliderInput("font_scale", "Размер шрифта подписей",
                  min = 0.3, max = 1.5, value = 0.8, step = 0.05),
      numericInput("max_labels", "Подписей на карте (топ по частоте)",
                   value = 250, min = 0, step = 50),
      helpText(em("Слова без подписи остаются точками -- видно, что рядом",
                  "что-то есть; слово показывается при наведении."))
    ),
    mainPanel(
      width = 9,
      plotlyOutput("word_map", height = "750px"),
      helpText("Наведите на слово -- увидите топ-5 характерных высказываний. ",
               "Кликните по слову -- откроется список всех высказываний с этим словом.")
    )
  )
)

# ==========================================================================
# SERVER
# ==========================================================================
server <- function(input, output, session) {

  rv <- reactiveValues(
    tags_log = load_tags_log(),
    stmt_tags = load_statement_tags(),
    modal_tag = NULL,     # тег, чьи высказывания открыты в модальном окне
    modal_stmts = NULL,   # их таблица (для исключения выбранных)
    edit_tag = NULL       # тег, из которого исключается слово
  )

  coords_rv      <- reactiveVal(word_coords %>% select(word, x, y))
  word_colors_rv <- reactiveVal(setNames(rep(DEFAULT_WORD_COLOR, nrow(word_coords)),
                                         word_coords$word))
  tag_colors_rv  <- reactiveVal(character(0))

  # ---- пересчёт состава тега (после исключения слова) --------------------
  recompute_tag <- function(tag_name) {
    row <- which(rv$tags_log$tag == tag_name)
    if (length(row) == 0) return(invisible())
    words <- intersect(split_tag_words(rv$tags_log$words[row]), rownames(emb))
    thr <- rv$tags_log$threshold[row]
    excl <- load_tag_exclusions() %>% filter(tag == tag_name) %>% pull(stmt_id)

    centroid <- colMeans(emb[words, , drop = FALSE])
    sims <- cosine_sim_vec_to_matrix(centroid, stmt_vecs_valid)
    names(sims) <- rownames(stmt_vecs_valid)
    matched <- as.integer(names(sims)[!is.na(sims) & sims >= thr])
    matched <- setdiff(matched, excl)

    stmt_tags <- rv$stmt_tags %>% filter(tag != tag_name)
    if (length(matched) > 0) {
      stmt_tags <- bind_rows(stmt_tags, tibble(
        stmt_id = matched, tag = tag_name,
        similarity = round(sims[as.character(matched)], 4)
      ))
    }
    rv$tags_log$n_statements[row] <- length(matched)
    rv$stmt_tags <- stmt_tags
    persist_tags(rv$tags_log, rv$stmt_tags)
  }

  # ---- данные для отображения (фильтры частоты и числа слов) -------------
  word_view <- reactive({
    minf <- if (isTruthy(input$min_word_freq)) input$min_word_freq else MIN_WORD_FREQ_DISPLAY
    maxw <- if (isTruthy(input$max_words)) input$max_words else MAX_WORDS_DISPLAY
    maxl <- if (!is.null(input$max_labels) && !is.na(input$max_labels)) input$max_labels else 250
    wc <- coords_rv() %>%
      left_join(word_meta, by = "word") %>%
      filter(freq >= minf) %>%
      arrange(desc(freq)) %>%
      head(maxw)
    # подписи только у топ-N частотных слов; остальные -- точки покрупнее
    wc$label <- ifelse(seq_len(nrow(wc)) <= maxl, wc$word, "")
    wc$color <- word_colors_rv()[wc$word]
    wc
  })

  # ---- график карты слов -------------------------------------------------
  output$word_map <- renderPlotly({
    wc <- word_view()
    fs <- if (isTruthy(input$font_scale)) input$font_scale else 0.8
    plot_ly(
      data = wc,
      x = ~x, y = ~y,
      type = "scatter", mode = "markers+text",
      text = ~label, textposition = "top center",
      textfont = list(size = ~pmax(5, pmin(10 + freq, 20) * fs), color = ~color),
      hovertext = ~hovertext, hoverinfo = "text",
      customdata = ~word,
      marker = list(size = ~ifelse(label == "", 6, 3), opacity = 0.5,
                    color = ~color, line = list(width = 0)),
      source = "wordmap"
    ) %>%
      layout(
        dragmode = "lasso",
        uirevision = "wordmap",   # сохранять зум при перерисовках
        xaxis = list(title = "", zeroline = FALSE, showticklabels = FALSE),
        yaxis = list(title = "", zeroline = FALSE, showticklabels = FALSE)
      ) %>%
      config(displaylogo = FALSE, scrollZoom = TRUE)
  })

  # ---- перестроить карту по тегам -----------------------------------------
  observeEvent(input$rebuild_btn, {
    tags_log <- rv$tags_log
    if (nrow(tags_log) == 0) {
      showNotification("Сначала создайте хотя бы один тег.", type = "warning")
      return(invisible())
    }

    centroids <- lapply(seq_len(nrow(tags_log)), function(i) {
      ws <- intersect(split_tag_words(tags_log$words[i]), rownames(emb))
      if (length(ws) == 0) return(NULL)
      colMeans(emb[ws, , drop = FALSE])
    })
    names(centroids) <- tags_log$tag
    centroids <- centroids[!vapply(centroids, is.null, logical(1))]
    if (length(centroids) == 0) {
      showNotification("Ни у одного тега нет слов, известных модели.", type = "warning")
      return(invisible())
    }

    withProgress(message = "Перестраиваю карту по тегам...", value = 0.1, {
      cent_mat <- do.call(rbind, centroids)
      tag_colors <- setNames(
        TAG_PALETTE[(seq_along(rownames(cent_mat)) - 1) %% length(TAG_PALETTE) + 1],
        rownames(cent_mat)
      )

      map_words <- word_coords$word
      emb_v <- emb[map_words, , drop = FALSE]
      emb_u <- emb_v / sqrt(rowSums(emb_v^2))
      cent_u <- cent_mat / sqrt(rowSums(cent_mat^2))
      sim_mat <- emb_u %*% t(cent_u)   # косинусные близости слово x тег

      incProgress(0.2, detail = "t-SNE...")

      # Фичи: исходные (нормированные) векторы + близости к тегам с бОльшим
      # весом. Текущие координаты передаются как Y_init -- t-SNE стартует из
      # них и локально дооптимизирует, поэтому слова смещаются умеренно
      # (аналог "штрафа за перемещение": ближайший доступный механизм в Rtsne).
      feat <- cbind(emb_u, TAG_FEATURE_WEIGHT * sim_mat)
      old <- coords_rv()
      Y0 <- as.matrix(old[match(map_words, old$word), c("x", "y")])

      perpl <- min(TSNE_PERPLEXITY, floor((nrow(feat) - 1) / 3))
      set.seed(TSNE_SEED)
      ts <- Rtsne(feat, dims = 2, perplexity = perpl, check_duplicates = FALSE,
                  pca = FALSE, Y_init = Y0, max_iter = 350)

      incProgress(0.5, detail = "раскраска...")

      best_idx <- max.col(sim_mat, ties.method = "first")
      best_sim <- sim_mat[cbind(seq_len(nrow(sim_mat)), best_idx)]
      word_col <- setNames(rep(DEFAULT_WORD_COLOR, length(map_words)), map_words)
      matched <- !is.na(best_sim) & best_sim > TAG_COLOR_SIMILARITY
      word_col[matched] <- tag_colors[rownames(cent_mat)[best_idx[matched]]]

      coords_rv(tibble(word = map_words, x = ts$Y[, 1], y = ts$Y[, 2]))
      word_colors_rv(word_col)
      tag_colors_rv(tag_colors)
    })
  })

  # ---- вернуть исходную карту ---------------------------------------------
  observeEvent(input$reset_map_btn, {
    coords_rv(word_coords %>% select(word, x, y))
    word_colors_rv(setNames(rep(DEFAULT_WORD_COLOR, nrow(word_coords)), word_coords$word))
    tag_colors_rv(character(0))
  })

  output$tag_color_legend <- renderUI({
    cols <- tag_colors_rv()
    if (length(cols) == 0) return(NULL)
    tagList(lapply(names(cols), function(tg) {
      tags$div(
        tags$span(style = sprintf(
          "display:inline-block;width:12px;height:12px;margin-right:6px;background:%s;border-radius:2px;",
          cols[tg]
        )),
        tg
      )
    }))
  })

  # ---- клик по слову -> модальное окно со всеми высказываниями ----------
  observeEvent(event_data("plotly_click", source = "wordmap"), {
    ed <- event_data("plotly_click", source = "wordmap")
    req(ed$customdata)
    w <- ed$customdata[1]
    ids <- word_to_stmt_ids[[w]]
    stmts <- df %>% filter(stmt_id %in% ids) %>% select(stmt_id, text_raw)

    showModal(modalDialog(
      title = sprintf("Слово: «%s» -- всего высказываний: %d", w, nrow(stmts)),
      DTOutput("modal_stmt_table"),
      size = "l", easyClose = TRUE, footer = modalButton("Закрыть")
    ))
    output$modal_stmt_table <- renderDT({
      datatable(stmts, colnames = c("ID", "Высказывание"), rownames = FALSE,
                options = list(pageLength = 15))
    })
  })

  # ---- лассо-выделение слов ----------------------------------------------
  selected_words_rv <- reactiveVal(character(0))

  observeEvent(event_data("plotly_selected", source = "wordmap"), {
    ed <- event_data("plotly_selected", source = "wordmap")
    if (is.null(ed) || nrow(ed) == 0) {
      selected_words_rv(character(0))
    } else {
      selected_words_rv(unique(ed$customdata))
    }
  })

  observeEvent(input$reset_selection_btn, {
    selected_words_rv(character(0))
    plotlyProxy("word_map", session) %>%
      plotlyProxyInvoke("relayout", list(selections = list()))
  })

  selected_words <- reactive({
    selected_words_rv()
  })

  output$selected_words_txt <- renderText({
    w <- selected_words()
    if (length(w) == 0) return("(слова не выделены)")
    paste0("Выделено (", length(w), "): ", paste(w, collapse = ", "))
  })

  # ---- предпросмотр: сколько высказываний попадёт под тег при текущем пороге ----
  tag_similarities <- reactive({
    words <- selected_words()
    req(length(words) > 0)
    centroid <- colMeans(emb[words, , drop = FALSE])
    sims <- cosine_sim_vec_to_matrix(centroid, stmt_vecs_valid)
    names(sims) <- rownames(stmt_vecs_valid)
    sims
  })

  output$preview_txt <- renderText({
    w <- selected_words()
    if (length(w) == 0) return("Выделите слова лассо, чтобы увидеть предпросмотр.")
    sims <- tag_similarities()
    n <- sum(sims >= input$tag_threshold, na.rm = TRUE)
    sprintf("При пороге %.2f будет помечено %d из %d высказываний (%.1f%%)",
            input$tag_threshold, n, length(sims), 100 * n / length(sims))
  })

  # ---- создание тега -------------------------------------------------------
  observeEvent(input$create_tag_btn, {
    words <- selected_words()
    tag_name <- trimws(input$tag_name)

    if (length(words) == 0) {
      output$tag_status <- renderText("Ошибка: сначала выделите слова лассо на карте.")
      return(invisible())
    }
    if (tag_name == "") {
      output$tag_status <- renderText("Ошибка: введите название тега.")
      return(invisible())
    }
    if (tag_name %in% rv$tags_log$tag) {
      output$tag_status <- renderText("Ошибка: тег с таким названием уже есть. Удалите старый или выберите другое имя.")
      return(invisible())
    }

    sims <- tag_similarities()
    matched_ids <- as.integer(names(sims)[sims >= input$tag_threshold])

    res <- append_tag(tag_name, words, input$tag_threshold, matched_ids, sims)
    rv$tags_log <- res$tags_log
    rv$stmt_tags <- res$stmt_tags

    output$tag_status <- renderText(sprintf(
      "Готово: тег «%s» присвоен %d высказываниям (из %d слов: %s). Сохранено в %s",
      tag_name, length(matched_ids), length(words), paste(words, collapse = ", "), BASE_WITH_TAGS_CSV
    ))

    updateTextInput(session, "tag_name", value = "")
  })

  output$tags_table <- renderDT({
    datatable(rv$tags_log, rownames = FALSE, selection = "single",
              options = list(pageLength = 5, dom = "tp"))
  })

  # выбранный в таблице тег (или NULL с уведомлением)
  selected_tag <- function() {
    row <- input$tags_table_rows_selected
    if (is.null(row) || length(row) == 0) {
      showNotification("Сначала выберите тег в таблице.", type = "warning")
      return(NULL)
    }
    rv$tags_log$tag[row]
  }

  # ---- высказывания тега (кнопка) -----------------------------------------
  observeEvent(input$show_tag_stmts_btn, {
    tg <- selected_tag(); req(tg)
    stmts <- rv$stmt_tags %>%
      filter(tag == tg) %>%
      left_join(df %>% select(stmt_id, text_raw), by = "stmt_id") %>%
      select(stmt_id, text_raw, similarity) %>%
      arrange(desc(similarity))
    rv$modal_tag <- tg
    rv$modal_stmts <- stmts

    showModal(modalDialog(
      title = sprintf("Тег: «%s» -- всего высказываний: %d", tg, nrow(stmts)),
      helpText("Отметьте строки и нажмите кнопку, чтобы принудительно исключить их ",
               "и похожие на них высказывания из тега (исключения запоминаются)."),
      fluidRow(
        column(6, sliderInput("sim_excl_threshold", "Порог похожести для \"похожих\"",
                              min = 0.5, max = 1, value = 0.95, step = 0.01)),
        column(6, br(), actionButton("exclude_stmts_btn", "Исключить выбранные и похожие",
                                     class = "btn-warning"))
      ),
      DTOutput("modal_tag_stmt_table"),
      size = "l", easyClose = TRUE, footer = modalButton("Закрыть")
    ))
    output$modal_tag_stmt_table <- renderDT({
      datatable(rv$modal_stmts, colnames = c("ID", "Высказывание", "Близость"),
                rownames = FALSE, selection = "multiple",
                options = list(pageLength = 15))
    })
  })

  # ---- исключить выбранные высказывания и похожие --------------------------
  observeEvent(input$exclude_stmts_btn, {
    req(rv$modal_tag, rv$modal_stmts)
    sel <- input$modal_tag_stmt_table_rows_selected
    if (is.null(sel) || length(sel) == 0) {
      showNotification("Отметьте хотя бы одну строку в таблице.", type = "warning")
      return(invisible())
    }
    tg <- rv$modal_tag
    thr <- if (isTruthy(input$sim_excl_threshold)) input$sim_excl_threshold else 0.95
    ids_sel <- rv$modal_stmts$stmt_id[sel]

    member_ids <- intersect(as.character(rv$modal_stmts$stmt_id), rownames(stmt_vecs_valid))
    M <- stmt_vecs_valid[member_ids, , drop = FALSE]

    to_excl <- ids_sel
    for (id in ids_sel) {
      key <- as.character(id)
      if (!key %in% rownames(stmt_vecs_valid)) next
      sims <- cosine_sim_vec_to_matrix(stmt_vecs_valid[key, ], M)
      to_excl <- c(to_excl, as.integer(member_ids[!is.na(sims) & sims >= thr]))
    }
    to_excl <- unique(to_excl)

    excl <- load_tag_exclusions()
    excl <- bind_rows(excl, tibble(tag = tg, stmt_id = to_excl)) %>% distinct()
    ensure_data_dir()
    write_csv(excl, TAG_EXCLUSIONS_CSV)

    rv$stmt_tags <- rv$stmt_tags %>% filter(!(tag == tg & stmt_id %in% to_excl))
    row <- which(rv$tags_log$tag == tg)
    rv$tags_log$n_statements[row] <- sum(rv$stmt_tags$tag == tg)
    persist_tags(rv$tags_log, rv$stmt_tags)

    removeModal()
    showNotification(sprintf(
      "Из тега «%s» исключено %d высказываний (выбрано %d, похожих при пороге %.2f: %d).",
      tg, length(to_excl), length(ids_sel), thr, length(to_excl) - length(ids_sel)
    ), type = "message", duration = 8)
  })

  # ---- исключить слово из тега ---------------------------------------------
  observeEvent(input$exclude_word_btn, {
    tg <- selected_tag(); req(tg)
    row <- which(rv$tags_log$tag == tg)
    words <- split_tag_words(rv$tags_log$words[row])
    rv$edit_tag <- tg
    showModal(modalDialog(
      title = sprintf("Исключить слово из тега «%s»", tg),
      checkboxGroupInput("words_to_exclude", "Слова тега (отметьте лишние):",
                         choices = words),
      helpText("После исключения состав высказываний тега пересчитывается ",
               "по оставшимся словам с тем же порогом."),
      footer = tagList(modalButton("Отмена"),
                       actionButton("confirm_exclude_word", "Исключить", class = "btn-warning"))
    ))
  })

  observeEvent(input$confirm_exclude_word, {
    req(rv$edit_tag)
    tg <- rv$edit_tag
    drop_words <- input$words_to_exclude
    if (is.null(drop_words) || length(drop_words) == 0) {
      showNotification("Отметьте хотя бы одно слово.", type = "warning")
      return(invisible())
    }
    row <- which(rv$tags_log$tag == tg)
    words <- setdiff(split_tag_words(rv$tags_log$words[row]), drop_words)
    if (length(intersect(words, rownames(emb))) == 0) {
      showNotification("Нельзя исключить все слова тега -- удалите тег целиком.", type = "error")
      return(invisible())
    }
    rv$tags_log$words[row] <- paste(words, collapse = ", ")
    recompute_tag(tg)
    removeModal()
    showNotification(sprintf("Слова исключены. Тег «%s» пересчитан: %d высказываний.",
                             tg, rv$tags_log$n_statements[which(rv$tags_log$tag == tg)]),
                     type = "message", duration = 8)
  })

  # ---- удалить тег ----------------------------------------------------------
  observeEvent(input$delete_tag_btn, {
    tg <- selected_tag(); req(tg)
    rv$tags_log <- rv$tags_log %>% filter(tag != tg)
    rv$stmt_tags <- rv$stmt_tags %>% filter(tag != tg)
    excl <- load_tag_exclusions() %>% filter(tag != tg)
    ensure_data_dir()
    write_csv(excl, TAG_EXCLUSIONS_CSV)
    persist_tags(rv$tags_log, rv$stmt_tags)
    showNotification(sprintf("Тег «%s» удалён.", tg), type = "message")
  })
}

shinyApp(ui, server)
