#!/usr/bin/env python3
import argparse
import csv
import json
import os
import sys
import tarfile
import tempfile


PREFIXES = {
    "commonsense": "cm",
    "deontology": "deontology",
    "justice": "justice",
    "utilitarianism": "util",
    "virtue": "virtue",
}

LABELED_SUBSETS = {"commonsense", "deontology", "justice", "virtue"}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Prepare ETHICS dataset into LogiQA-style JSONL."
    )
    parser.add_argument(
        "--input",
        required=True,
        help="Path to ethics.tar or extracted ethics directory",
    )
    parser.add_argument(
        "--output",
        default="Artifacts/Datasets/ETHICS/prepared",
        help="Output directory for prepared JSONL",
    )
    parser.add_argument(
        "--subsets",
        default="commonsense,deontology,justice,virtue",
        help="Comma-separated subsets to include",
    )
    parser.add_argument(
        "--label-mode",
        default="label",
        choices=["label", "yesno"],
        help="How to encode labels into answer_text",
    )
    parser.add_argument(
        "--train-limit",
        type=int,
        default=0,
        help="Limit number of train rows per subset (0 = no limit)",
    )
    parser.add_argument(
        "--valid-limit",
        type=int,
        default=0,
        help="Limit number of valid rows per subset (0 = no limit)",
    )
    return parser.parse_args()


def resolve_data_root(input_path):
    if os.path.isdir(input_path):
        if os.path.basename(input_path) == "ethics":
            return input_path, None
        candidate = os.path.join(input_path, "ethics")
        if os.path.isdir(candidate):
            return candidate, None
        raise ValueError(f"Could not find ethics/ under {input_path}")

    if input_path.endswith(".tar") and os.path.isfile(input_path):
        temp_dir = tempfile.TemporaryDirectory()
        with tarfile.open(input_path, "r:*") as tar:
            tar.extractall(path=temp_dir.name)
        root = os.path.join(temp_dir.name, "ethics")
        if not os.path.isdir(root):
            temp_dir.cleanup()
            raise ValueError("Extracted archive does not contain ethics/ root")
        return root, temp_dir

    raise ValueError(f"Input path not found: {input_path}")


def label_text(label, mode):
    if label not in (0, 1):
        raise ValueError(f"Expected binary label, got {label}")
    if mode == "label":
        return f"LABEL_{label}"
    if mode == "yesno":
        return "YES" if label == 1 else "NO"
    raise ValueError(f"Unknown label mode: {mode}")


def make_record(subset, row, split, idx, label_mode):
    if subset == "commonsense":
        label = int(row["label"])
        input_text = row["input"].strip()
    elif subset == "deontology":
        label = int(row["label"])
        scenario = row["scenario"].strip()
        excuse = row["excuse"].strip()
        input_text = scenario if not excuse else f"{scenario}\nExcuse: {excuse}"
    elif subset == "justice":
        label = int(row["label"])
        input_text = row["scenario"].strip()
    elif subset == "virtue":
        label = int(row["label"])
        scenario_raw = row["scenario"].strip()
        if " [SEP] " in scenario_raw:
            scenario, trait = scenario_raw.split(" [SEP] ", 1)
            scenario = scenario.strip()
            trait = trait.strip()
        else:
            scenario = scenario_raw
            trait = ""
        input_text = scenario if not trait else f"{scenario}\nTrait: {trait}"
    else:
        raise ValueError(f"Unsupported labeled subset: {subset}")

    if not input_text:
        raise ValueError(f"Empty input_text for {subset} row {idx}")

    answer = label_text(label, label_mode)
    wrong = label_text(1 - label, label_mode)
    return {
        "id": f"{subset}-{split}-{idx}",
        "split": split,
        "input_text": input_text,
        "answer_text": answer,
        "wrong_answers": [wrong],
    }


def convert_split(csv_path, subset, split, output_path, label_mode, limit):
    if not os.path.isfile(csv_path):
        raise FileNotFoundError(csv_path)
    count = 0
    with open(csv_path, newline="", encoding="utf-8") as f, open(
        output_path, "w", encoding="utf-8"
    ) as out:
        reader = csv.DictReader(f)
        for idx, row in enumerate(reader):
            record = make_record(subset, row, split, idx, label_mode)
            out.write(json.dumps(record, ensure_ascii=False) + "\n")
            count += 1
            if limit > 0 and count >= limit:
                break
    return count


def main():
    args = parse_args()
    subsets = [s.strip() for s in args.subsets.split(",") if s.strip()]
    for subset in subsets:
        if subset not in PREFIXES:
            raise ValueError(f"Unknown subset: {subset}")
        if subset == "utilitarianism":
            raise ValueError(
                "utilitarianism has no labels in ETHICS; "
                "exclude it or provide a labeled variant"
            )
        if subset not in LABELED_SUBSETS:
            raise ValueError(f"Subset not supported: {subset}")

    data_root, temp_dir = resolve_data_root(args.input)
    os.makedirs(args.output, exist_ok=True)

    try:
        for subset in subsets:
            prefix = PREFIXES[subset]
            train_csv = os.path.join(data_root, subset, f"{prefix}_train.csv")
            test_csv = os.path.join(data_root, subset, f"{prefix}_test.csv")
            train_out = os.path.join(args.output, f"{subset}_train.jsonl")
            valid_out = os.path.join(args.output, f"{subset}_valid.jsonl")

            train_count = convert_split(
                train_csv,
                subset,
                "train",
                train_out,
                args.label_mode,
                args.train_limit,
            )
            valid_count = convert_split(
                test_csv,
                subset,
                "valid",
                valid_out,
                args.label_mode,
                args.valid_limit,
            )
            print(
                f"{subset}: train={train_count} -> {train_out}, "
                f"valid={valid_count} -> {valid_out}"
            )
    finally:
        if temp_dir is not None:
            temp_dir.cleanup()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
