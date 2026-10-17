"""ACE Studio lyricist: ACE-Step's built-in 5Hz LM (1.7B, MLX) in a one-shot process.

It loads the LM, runs "create sample" (description -> style, lyrics, BPM, key,
duration) and exits, so the LM's RAM is free again before the music model runs.

stdin:  {"query": "...", "instrumental": false, "language": "it", "temperature": 0.7}
stdout: one line "@@RESULT@@" + JSON
"""
import json
import os
import re
import sys
import time

ACE_DIR = os.path.expanduser("~/ACE-Step-1.5")
sys.path.insert(0, ACE_DIR)
os.chdir(ACE_DIR)

AUDIO_CODE = re.compile(r"<\|audio_code_\d+\|>")
SPECIAL = re.compile(r"<\|[^|>]*\|>")


def emit(obj):
    print("@@RESULT@@" + json.dumps(obj, ensure_ascii=False), flush=True)


def clean_lyrics(text):
    text = AUDIO_CODE.sub("", text or "")
    text = SPECIAL.sub("", text)
    out = []
    for line in text.splitlines():
        line = line.rstrip()
        # drop stray non-latin fragments the small LM sometimes emits in latin-script songs
        line = re.sub(r"[Ѐ-ӿ一-鿿぀-ヿ]+", "", line)
        out.append(line)
    text = "\n".join(out)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def main():
    req = json.loads(sys.stdin.read() or "{}")
    from acestep.llm_inference import LLMHandler

    t0 = time.time()
    llm = LLMHandler()
    status, ok = llm.initialize(
        checkpoint_dir=os.path.join(ACE_DIR, "checkpoints"),
        lm_model_path=os.environ.get("ACESTUDIO_LM", "acestep-5Hz-lm-1.7B"),
        backend="mlx",
        device="mps",
        offload_to_cpu=False,
        dtype=None,
    )
    if not ok:
        emit({"ok": False, "error": f"LLM di ACE non caricato: {status}"})
        return
    load_s = time.time() - t0

    lang = req.get("language") or "unknown"

    if req.get("mode") == "codes":
        # "Thinking" plan: 5Hz audio codes (melody/structure) that the DiT then follows.
        dur = float(req.get("duration", 60))
        md = {"duration": str(int(dur))}
        if req.get("bpm"):
            md["bpm"] = str(int(req["bpm"]))
        if req.get("key"):
            md["keyscale"] = req["key"]
        if lang != "unknown":
            md["language"] = lang
        md["timesignature"] = "4"
        r = llm.generate_with_stop_condition(
            caption=req.get("style", ""),
            lyrics=req.get("lyrics", ""),
            infer_type="llm_dit",
            temperature=float(req.get("temperature", 0.85)),
            cfg_scale=float(req.get("cfg_scale", 2.0)),
            top_p=0.9,
            target_duration=dur,
            user_metadata=md,
            use_cot_caption=False,
            use_cot_language=False,
        )
        if not r.get("success"):
            emit({"ok": False, "error": r.get("error") or "codici audio non generati"})
            return
        codes = r.get("audio_codes") or ""
        if isinstance(codes, list):
            codes = codes[0] if codes else ""
        emit({"ok": True, "codes": codes, "n_codes": codes.count("<|audio_code_"),
              "load_seconds": round(load_s, 1), "total_seconds": round(time.time() - t0, 1)})
        return

    meta, status = llm.create_sample_from_query(
        query=req.get("query", ""),
        instrumental=bool(req.get("instrumental", False)),
        vocal_language=lang,
        temperature=float(req.get("temperature", 0.7)),
        top_p=float(req.get("top_p", 0.9)),
        repetition_penalty=float(req.get("repetition_penalty", 1.05)),
    )
    if not meta:
        emit({"ok": False, "error": status})
        return

    def num(v):
        try:
            return int(float(v))
        except (TypeError, ValueError):
            return None

    emit({
        "ok": True,
        "style": (meta.get("caption") or "").strip(),
        "lyrics": "[Instrumental]" if req.get("instrumental") else clean_lyrics(meta.get("lyrics", "")),
        "bpm": num(meta.get("bpm")),
        "duration": num(meta.get("duration")),
        "key": (meta.get("keyscale") or "").strip(),
        "language": meta.get("language") or lang,
        "load_seconds": round(load_s, 1),
        "total_seconds": round(time.time() - t0, 1),
    })


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001
        emit({"ok": False, "error": str(exc)[:400]})
