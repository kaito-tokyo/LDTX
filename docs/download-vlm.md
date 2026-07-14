<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Download Vision Models

LDTX uses vision-language models from the standard Hugging Face Hub cache.
Model downloads are intentionally performed outside LDTX so that installing a
large model is always an explicit user action.

## Install the Hugging Face CLI

Install the `hf` command with Homebrew:

```sh
brew install hf
```

Alternatively, use the standalone installer documented by Hugging Face:

```sh
curl -LsSf https://hf.co/cli/install.sh | bash
```

Verify the installation:

```sh
hf --help
```

## Download a model

Download either or both supported models:

```sh
hf download mlx-community/Qwen3-VL-2B-Instruct-4bit
hf download lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit
```

The CLI stores these models in the standard Hugging Face cache, which is also
where LDTX looks for them. Do not use `--local-dir`, because a separate local
directory is not detected by LDTX.

After the command completes, reopen LDTX Settings to refresh the installation
status.

For more information, see the
[Hugging Face CLI documentation](https://huggingface.co/docs/huggingface_hub/guides/cli).
