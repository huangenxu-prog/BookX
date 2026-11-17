# Offline speech dependencies

- Kokoro-82M-v1.1-zh by hexgrad: https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh (Apache-2.0).
- ONNX INT8 distribution by sherpa-onnx: https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models ; archive `kokoro-int8-multi-lang-v1_1.tar.bz2`, SHA-256 `259c9c8bc906d6078e4e0570421885dabb68b539c2f970fcbb890a58eeaf3e9c`. The upstream LICENSE and resource tree remain in the app's Kokoro folder.
- sherpa-onnx: https://github.com/k2-fsa/sherpa-onnx (Apache-2.0), pinned at `af2d8d81dbfa61c4cea4c568da78f3982edca005`. BookX calls the upstream Swift wrapper instead of copying its implementation.
- ONNX Runtime: https://github.com/microsoft/onnxruntime (MIT), resolved by the pinned sherpa-onnx package.
- ZIPFoundation: https://github.com/weichsel/ZIPFoundation (MIT).

The model bundle contains upstream text-processing dictionaries and voice resources. Do not strip their included notices when repackaging. No model weights are committed to this source repository.
