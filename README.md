# Open answers map

Russian version: [README.ru.md](README.ru.md)

Two tools for coding open-ended survey answers. Both work on the output of one shared preprocessing pipeline (R, with an optional Python embedding step).

1. **Automatic tag map by segment** (`map/`). Answers are split into tags and subtags automatically, so that the tags differ between respondent segments as much as possible. The result is a single HTML page with zoom, segment highlighting and a filter by whether an answer matched its segment.
2. **Word map** (`app.R`, Shiny). The researcher lasso-selects a group of words on a 2-D map, names the tag and sets a similarity threshold; answers close in meaning to the selected words get the tag. The result is a set of CSV files in `data/`.

The repository contains code only. Input data and all results contain respondents' answers, so `.gitignore` excludes `data/`, `map/out/` and the `*.sav`, `*.rds`, `*.bin`, `*.csv`, `*.xlsx`, `*.parquet` file types. Do not commit them.

The code does not send answers anywhere: embeddings are computed locally. Network access is used only to download R packages, the lemmatization model and the embedding model.

## Requirements

- R. `install_packages.R` installs the packages the project uses: `haven`, `dplyr`, `stringr`, `tidyr`, `udpipe`, `stopwords`, `word2vec`, `Rtsne`, `shiny`, `plotly`, `DT`, `readr`, `jsonlite`, `nnet`. On Windows, packages without a binary build need Rtools.
- Python 3 with `sentence-transformers` and `pandas` for the default embedding source (`"llm"`). With `EMBEDDING_SOURCE <- "word2vec"` Python is needed only to run `map/build.py`, which uses the standard library.
- Internet access on the first run: `pipeline/02_preprocess.R` downloads the Russian udpipe model (about 44 MB) into `data/udpipe_model/`, and `pipeline/embed_local.py` downloads the embedding model (about 1 GB).
- Input: an SPSS `.sav` file with one open-ended text variable. The automatic tag map also needs a segment variable.

## Quick start

All commands are run from the repository root (the scripts use relative paths).

```
Rscript install_packages.R
python -m pip install sentence-transformers pandas
```

Edit `pipeline/00_config.R` (see [Configuration](#configuration)), then:

```
Rscript run_pipeline.R        # .sav -> lemmas -> vectors -> data/04_app_data.rds

Rscript run_app.R             # word map (Shiny), opens a browser

Rscript map/01_cluster.R      # tags fitted to segments, prints quality metrics
Rscript map/02_export.R       # map layouts, map/out/data.json and map/out/summary.txt
python map/build.py           # builds map/out/map.html
```

## Configuration

All settings live in `pipeline/00_config.R`; the pipeline, `app.R` and the `map/` scripts all source it. Set these before the first run:

| Constant | Default | Meaning |
|---|---|---|
| `RAW_SAV_PATH` | `"data/raw/survey.sav"` | path to the `.sav` file |
| `TEXT_VAR` | `"OPEN"` | variable with the open-ended answers |
| `SEGMENT_VAR` | `"SEGMENT"` | segment variable for `map/`: a number, text or a labelled SPSS variable |

Other settings:

| Constant | Default | Meaning |
|---|---|---|
| `EMBEDDING_SOURCE` | `"llm"` | `"llm"` or `"word2vec"`, see [Embedding sources](#embedding-sources) |
| `LLM_EMB_MODEL` | `"paraphrase-multilingual-mpnet-base-v2"` | sentence-transformers model |
| `PYTHON_BIN` | `"python"` | Python executable called from R |
| `MAP_K_FINE`, `MAP_K_MID`, `MAP_K_TOP` | 120, 36, 12 | number of fine clusters, subtags and tags; lower them for a much smaller dataset |
| `MAP_LAMBDA` | 3 | weight of the loss of segment information when merging clusters (0 = meaning only) |
| `MAP_W_SEG` | 0.5 | weight of text-predicted segment probabilities in the fine clustering |
| `DEFAULT_TAG_SIMILARITY_THRESHOLD` | 0.50 for `"llm"`, 0.85 for `"word2vec"` | initial tag threshold in the app |
| `TAG_COLOR_SIMILARITY` | 0.45 for `"llm"`, 0.60 for `"word2vec"` | similarity above which a word takes the colour of its nearest tag |
| `TAG_FEATURE_WEIGHT` | 3 | weight of tag similarities when the word map is rebuilt by tags |
| `MIN_WORD_FREQ_ON_MAP` | 3 | minimum lemma frequency for a word to be included in the map data |
| `MIN_WORD_FREQ_DISPLAY`, `MAX_WORDS_DISPLAY` | 5, 3000 | initial display filters in the app |
| `TOP_N_CHARACTERISTIC` | 5 | number of example answers per word |
| `TSNE_PERPLEXITY`, `TSNE_SEED` | 15, 42 | t-SNE settings of the word map |
| `W2V_TYPE`, `W2V_DIM`, `W2V_WINDOW`, `W2V_MIN_COUNT`, `W2V_ITER`, `W2V_NEGATIVE` | `"skip-gram"`, 30, 5, 4, 20, 10 | word2vec training settings |
| `MIN_TOKEN_LEN`, `NORMALIZE_YO` | 2, `TRUE` | minimum lemma length; replace "ё" with "е" |

According to the comments in the config, the word2vec settings and the default thresholds were tuned on a corpus of a few thousand short answers.

## Pipeline

`Rscript run_pipeline.R` runs the steps in order. Each step sources the config itself and can also be run separately; steps exchange data through files in `data/`.

| Step | What it does | Output |
|---|---|---|
| `pipeline/01_load_data.R` | reads the `.sav`, renames `TEXT_VAR` to `text_raw`, adds `stmt_id`, drops empty answers, converts labelled SPSS columns to factors | `data/01_raw.rds` |
| `pipeline/02_preprocess.R` | lower-cases and cleans the text, lemmatizes it with udpipe (`russian-syntagrus`), keeps nouns, verbs, adjectives, adverbs and proper nouns, removes stop words | `data/02_preprocessed.rds` |
| `pipeline/03b_embed_llm.R` (source `"llm"`) | embeds whole answers and the map vocabulary with `pipeline/embed_local.py` | `data/03b_llm_embeddings.rds` |
| `pipeline/03_train_word2vec.R` (source `"word2vec"`) | trains word2vec on the lemmatized corpus | `data/03_word2vec.bin` |
| `pipeline/04_prepare_app_data.R` | t-SNE of the word vectors, answer vectors, word-to-answer index, example answers per word | `data/04_app_data.rds` |

The particle "не" is merged with the next content word, so "не тратить" becomes the lemma `не_тратить`. The script reports that lemmatization may take a couple of minutes.

## Automatic tag map

```
Rscript run_pipeline.R
Rscript map/01_cluster.R
Rscript map/02_export.R
python map/build.py
```

`map/build.py` inserts `map/out/data.json` into `map/template.html` and writes `map/out/map.html`. The page is one file: the data is inlined and the template loads no external scripts, styles or fonts. Open it in a browser or serve `map/out/` with any static file server.

### Tag names

Without names, labels are built from the common words of each cluster. To set your own, read `map/out/summary.txt` and create `map/out/names.json`; the order of the names follows the `TOP` and `MID` numbers in the summary. Then rerun `map/02_export.R` and `map/build.py`.

```json
{"top": ["Tag name 1", "Tag name 2"], "mid": ["Subtag name 1"]}
```

If `map/01_cluster.R` is rerun with other settings or on other data, cluster numbers change and the names have to be assigned again.

### How the split is built

1. Answer vectors are normalized and reduced with PCA. A multinomial model (`nnet`) predicts the segment from the text in 5-fold cross-validation.
2. Answers are split into `MAP_K_FINE` fine clusters with k-means on the PCA components plus the predicted segment probabilities weighted by `MAP_W_SEG`.
3. Fine clusters are merged bottom-up into `MAP_K_MID` subtags and `MAP_K_TOP` tags. Only neighbours in meaning can be merged, and among them the pair with the lowest cost is taken: distance in meaning (Ward) plus `MAP_LAMBDA` times the loss of information about the segment.
4. `map/02_export.R` builds two layouts. The first is t-SNE on the PCA components with subtag and tag membership added as extra features. The second is t-SNE on the affinity of each answer to every segment (cosine to the segment centroid; for the answer's own segment the centroid is computed without that answer).

### Reading the result

`map/01_cluster.R` prints the metrics and saves them with the clusters in `map/out/clusters.rds`:

- `V_seg` — association between tags and segments (Cramér's V);
- `V_base` — the same for plain k-means with the same number of groups; this is the value to compare with;
- `V_perm` — the same with segment labels shuffled;
- `V_mid`, `V_fine` — the same for subtags and fine clusters;
- `acc` and `majority` — how often the segment is predicted from the text, and the share of the largest segment. If they are close, the text says little about the segment and a high `V_seg` cannot be expected;
- `within_top`, `within_base` — within-group share of variance for the tags and for the plain k-means groups;
- `minsize`, `maxsize` — size of the smallest and the largest tag.

The page header shows `V_seg`, `V_base` and `V_perm`.

On the page (its interface text is in Russian):

- zooming in switches the labels from tags to subtags and then to fine clusters; the mouse wheel zooms after a click on the map or with Ctrl held, and clicking a label zooms to the next level;
- "Раскладка" (layout) switches between "по смыслу (теги — области)" (by meaning, tags as areas) and "по близости к сегментам" (by affinity to segments);
- "Подсветить сегмент" (highlight a segment) dims the answers of other segments;
- "Показать ответы" (show answers) filters by "все" (all), "совпали с сегментом" (matched the segment) and "не совпали" (did not match);
- hovering over a label shows the segment profile, common words and example answers; hovering over a point shows the answer text.

Each tag, subtag and fine cluster has an index per segment: 100 means the segment's share in the cluster equals its share in the whole dataset. An answer "matched" when it comes from a segment whose index is 130 or more for the tag (after zooming in, for the subtag or fine cluster).

## Word map (Shiny app)

```
Rscript run_pipeline.R
Rscript run_app.R
```

`run_app.R` calls `shiny::runApp(".", launch.browser = TRUE)`. The app reads only `data/04_app_data.rds` and stops with an error if it is missing.

1. Each word is a point; the most frequent words are labelled (250 by default, set in "Подписей на карте (топ по частоте)", number of labels on the map), and the label size grows with frequency up to a cap. Hovering over a word shows its 5 most characteristic answers, clicking opens all answers that contain the word.
2. Select a group of words with the lasso. Enter "Название тега" (tag name) and set "Порог косинусной близости" (cosine similarity threshold); the preview shows how many answers would be tagged. "Создать тег" (create tag) saves the tag. An answer gets the tag when the cosine similarity between its vector and the mean vector of the selected words is at or above the threshold.
3. For a tag selected in the table: "Высказывания" (statements) lists its answers and lets you remove selected answers together with similar ones ("Исключить выбранные и похожие"); "Исключить слово" (exclude word) removes words from the tag and recomputes it; "Удалить тег" (delete tag) deletes the tag immediately, without confirmation.
4. "Перестроить по тегам" (rebuild by tags) reruns t-SNE on the word vectors plus the similarities of the words to the tags, starting from the current positions, and colours each word by its nearest tag. "Исходная карта" (original map) restores the initial layout.
5. "Настройки карты" (map settings) holds the display filters: minimum word frequency, maximum number of words, label font size and number of labels.

Tags are stored in `data/`:

- `tags_log.csv` — tag name, words, threshold, number of answers, creation time;
- `statement_tags.csv` — answer id, tag, similarity;
- `tag_exclusions.csv` — answers removed from a tag by hand;
- `base_with_tags.csv` — the source table with a `tags` column next to the answer text. This is the file for further analysis.

The pipeline does not touch these files. After the vectors are recomputed, existing tags may no longer correspond to the new vectors.

## Embedding sources

The switch is `EMBEDDING_SOURCE` in `pipeline/00_config.R`.

- `"llm"` (default) — a local sentence-transformers model, `paraphrase-multilingual-mpnet-base-v2`. Each answer is embedded as a whole from its raw text, and the map words are embedded with the same model, so words and answers share one vector space. Working tag thresholds are usually 0.4–0.7.
- `"word2vec"` — vectors are trained on the corpus itself with the R package `word2vec`, without Python. An answer vector is the mean of its lemma vectors. On a small corpus similarities are compressed towards 1, so thresholds are usually 0.8–0.95.

After switching the source, rerun the pipeline and recreate the tags: thresholds in the two spaces are not comparable.

## Repository structure

```
app.R, run_app.R         Shiny app (word map)
run_pipeline.R           full pipeline run
install_packages.R       installs R packages
pipeline/
  00_config.R            all settings
  01_load_data.R         reads the .sav file
  02_preprocess.R        cleaning and lemmatization (udpipe)
  03_train_word2vec.R    word2vec vectors
  03b_embed_llm.R        sentence-transformers embeddings (calls embed_local.py)
  embed_local.py         embeds a CSV of texts, called from 03b_embed_llm.R
  04_prepare_app_data.R  t-SNE of words and data for the app
map/
  01_cluster.R           split into tags fitted to segments
  02_export.R            layouts, data.json, summary.txt
  template.html          map page template
  build.py               builds map/out/map.html
CLAUDE.md                project notes for a coding agent (in Russian)
data/, map/out/          created at run time, not in the repository
```

## Limitations

- Russian only. The lemmatization model, the stop-word list and the text cleaning (only Cyrillic and Latin letters, digits and hyphens are kept) are set up for Russian. The interface of the Shiny app and of the map page is in Russian.
- The input is an SPSS `.sav` file with one open-ended variable.
- `map/out/map.html`, `map/out/data.json` and the files in `data/` contain the full text of the answers. Treat them as respondent data.
- In the first layout of the map, tags are separated more clearly than on a plain map of meaning, because tag membership is one of its inputs. Distances between tags are partly artificial, and visual separation does not prove tag quality.
- "Matched the segment" is not a share of correctly predicted segments: a tag can have several segments with an index of 130 or more.
- The split is fitted to the same segments it is then evaluated on, so `V_seg` is somewhat optimistic. Check the names and the content of the tags by eye.
- The map page uses 8 colours, assigned so that neighbouring tags differ. A colour does not identify a tag; labels do.
- Tag thresholds depend on the embedding source, and stored tags are not recomputed when the vectors change.

## License

MIT — see [LICENSE](LICENSE).
