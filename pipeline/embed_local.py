# =========================================================================
# embed_local.py -- локальные LLM-эмбеддинги через sentence-transformers
# Вызывается из R (pipeline/03b_embed_llm.R):
#   python pipeline/embed_local.py <model> <in.csv> <out.csv>
# in.csv:  столбцы id, text
# out.csv: столбец id + столбцы v1..vN (нормированные вектора)
# Модель скачивается автоматически при первом запуске (~1 ГБ, нужен интернет),
# затем кэшируется в ~/.cache/huggingface.
# =========================================================================
import sys

import pandas as pd
from sentence_transformers import SentenceTransformer


def main() -> None:
    model_name, in_csv, out_csv = sys.argv[1], sys.argv[2], sys.argv[3]

    df = pd.read_csv(in_csv)
    texts = df["text"].astype(str).tolist()
    print(f"Эмбеддинг {len(texts)} текстов моделью {model_name}...", flush=True)

    model = SentenceTransformer(model_name)
    emb = model.encode(
        texts,
        batch_size=64,
        show_progress_bar=True,
        normalize_embeddings=True,  # косинус = скалярное произведение
    )

    out = pd.DataFrame(emb, columns=[f"v{i+1}" for i in range(emb.shape[1])])
    out.insert(0, "id", df["id"].values)
    out.to_csv(out_csv, index=False)
    print(f"Сохранено: {out_csv} ({emb.shape[0]} x {emb.shape[1]})", flush=True)


if __name__ == "__main__":
    main()
