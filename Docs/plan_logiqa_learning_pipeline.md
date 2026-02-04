# LogiQA Learning Pipeline Plan (MVP)

Status: proposed
Owner: EnergeticCore
Scope: local, cached training on LogiQA (context + query → correct option), with negative sampling from wrong options.

## Goals
- Train Flow router to map question inputs to answer targets via Capsule bins.
- Keep data local (no remote downloads during training runs).
- Support train/valid split using dataset’s official splits.
- Add negative learning: push outputs away from incorrect options (contrastive loss).
- Provide simple metrics: option accuracy + capsule decode accuracy + bin distance.

## Dataset (LogiQA)
- Source: `lucasmccabe/logiqa`.
- Fields: `context`, `query`, `answers` (list of options), `correct_option`.
- Splits: train/validation/test.

## Data representation
### Input
`input_text = context + "\nQuestion: " + query`

### Target (positive)
`answer_text = answers[correct_option]`

### Negative targets
`wrong_answers = answers[all indices != correct_option]`

## Local data workflow (no online dependency)
1) **One-time fetch**
   - Use a small Python script to download LogiQA via Hugging Face `datasets`.
   - Save raw JSONL to `Artifacts/Datasets/LogiQA/raw/`.
2) **Preparation (cached)**
   - Build `prepared.jsonl` with fields:
     - `id`, `split`, `input_text`, `answer_text`, `wrong_answers`.
   - Optionally precompute Capsule outputs for speed:
     - `input_energies` (UInt16 list)
     - `answer_targets` (Float bins)
     - `wrong_targets` (list of Float bins)
   - Save to `Artifacts/Datasets/LogiQA/prepared/`.
3) **Training uses only local files**
   - Config provides dataset path; training code reads prepared JSONL.

## Learning objective (MVP)
### Positive (existing)
- **Bin loss**: `L_pos = ||yHat - T_correct||^2`.

### Negative (new)
- **Margin repulsion** for wrong options:
  - For each wrong target `T_wrong`:
    - `d = ||yHat - T_wrong||_2`
    - `L_neg = mean(max(0, margin - d)^2)`
  - Total: `L = L_pos + w_neg * L_neg + w_spike * L_spike + w_boundary * L_boundary`

### Alternative (option accuracy)
- Choose answer by minimal bin distance:
  - `argmin_k ||yHat - T_option_k||`
- Track accuracy vs correct option (valid split).

## Config additions (YAML)
Add under `router.flow.learning`:
```yaml
learning:
  dataset:
    name: "logiqa"
    local_path: "Artifacts/Datasets/LogiQA/prepared/prepared.jsonl"
    cache_mode: "precomputed"   # raw | prepared | precomputed
    train_limit: 256
    valid_limit: 64
    shuffle: true
    seed: 42
  negative:
    enabled: true
    weight: 0.2
    margin: 0.5
```

## Training loop changes
1) **Data loader**
   - Read prepared JSONL and yield batches.
2) **Targets**
   - Use precomputed `answer_targets` if available; else compute on the fly.
   - For negatives, use `wrong_targets` or compute from `wrong_answers`.
3) **Loss**
   - Add `L_neg` term.
4) **Metrics**
   - `acc_option`: argmin bin distance vs correct.
   - `acc_decode`: decode recovered answer text and compare to correct answer.
   - `bin_dist_pos`: average L2 to correct.

## Evaluation (valid split)
- Option accuracy (bin similarity)
- Capsule decode exact match
- Mean bin distance to correct
- Mean margin to wrongs

## Deliverables
- `Tools/logiqa_prepare.py` (download + prepare + optional precompute)
- `Artifacts/Datasets/LogiQA/` (local cache)
- Config schema updates and docs
- Learning loop update for negative loss

## MVP sequence
1) Add preparation script + local cache layout.
2) Extend ConfigCenter schema for dataset + negative loss.
3) Implement data loader for prepared JSONL.
4) Add negative loss term in learning loop.
5) Add validation metrics (option acc + decode acc).
6) Run pilot: train=256, valid=64, fixed seed.

## Risks / notes
- Capsule decode accuracy can be harsh; option accuracy may be more stable early.
- Negative loss should be bounded (margin) to avoid runaway divergence.
- Keep batch sizes small for deterministic debugging.

