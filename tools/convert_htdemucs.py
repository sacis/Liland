"""Converts HTDemucs (Meta's music source separation network) to the Core ML model Liland ships.

Only the network goes into the model. The spectrogram it reads, the inverse that turns its
output back into sound, and the normalization around both are done by `DemucsSplitter.swift`,
in single precision, since the network itself runs in half precision on the Neural Engine.

The shapes are fixed: 44 spectrogram frames, about one second of music at 44.1 kHz.

Liland runs it on the GPU. On the Neural Engine some of its half-precision sums overflow and the
parts come out wrong (about 8 dB from the original instead of 49 dB on the GPU), and it isn't
faster there anyway (18 ms against 15 ms for one second of music on an M5).

    python3.11 -m venv venv
    venv/bin/pip install torch demucs coremltools
    venv/bin/python tools/convert_htdemucs.py

It writes Liland/Resources/HTDemucs.mlpackage and prints how closely the Core ML model
follows the original.
"""

import os

import coremltools as ct
import numpy as np
import torch
from demucs.pretrained import get_model
from demucs.transformer import create_2d_sin_embedding
from einops import rearrange

FRAMES = 44
HOP = 1024
SAMPLES = FRAMES * HOP
BINS = 2048
OUTPUT = os.path.join(os.path.dirname(__file__), "..", "Liland", "Resources", "HTDemucs.mlpackage")


class Network(torch.nn.Module):
    """`HTDemucs.forward` between its normalization and its inverse spectrogram (demucs 4.1.0)."""

    def __init__(self, model, spectrum, wave):
        super().__init__()
        self.model = model
        # The transformer works out its position embeddings from the shapes it gets, with Python
        # arithmetic Core ML can't follow. The shapes are fixed, so they're worked out once here.
        shapes = {}
        hook = model.crosstransformer.register_forward_hook(
            lambda _, inputs, __: shapes.update(x=inputs[0].shape, xt=inputs[1].shape)
        )
        with torch.no_grad():
            model(torch.zeros(1, 2, wave.shape[-1]))
        hook.remove()
        cross = model.crosstransformer
        _, channels, bands, frames = shapes["x"]
        position = create_2d_sin_embedding(channels, bands, frames, "cpu", cross.max_period)
        self.register_buffer("position", rearrange(position, "b c fr t1 -> b (t1 fr) c"))
        position_t = cross._get_pos_embedding(shapes["xt"][-1], 1, channels, "cpu")
        self.register_buffer("position_t", rearrange(position_t, "t2 b c -> b t2 c"))

    def cross(self, x, xt):
        """`CrossTransformerEncoder.forward` with the positions worked out beforehand."""
        cross = self.model.crosstransformer
        frames = x.shape[-1]
        x = rearrange(x, "b c fr t1 -> b (t1 fr) c")
        x = cross.norm_in(x) + cross.weight_pos_embed * self.position
        xt = rearrange(xt, "b c t2 -> b t2 c")
        xt = cross.norm_in_t(xt) + cross.weight_pos_embed * self.position_t
        for idx in range(cross.num_layers):
            if idx % 2 == cross.classic_parity:
                x = cross.layers[idx](x)
                xt = cross.layers_t[idx](xt)
            else:
                old_x = x
                x = cross.layers[idx](x, xt)
                xt = cross.layers_t[idx](xt, old_x)
        x = rearrange(x, "b (t1 fr) c -> b c fr t1", t1=frames)
        xt = rearrange(xt, "b t2 c -> b c t2")
        return x, xt

    def forward(self, spectrum, wave):
        m = self.model
        x, xt = spectrum, wave
        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(m.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(m.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = m.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and m.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                emb = m.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                x = x + m.freq_emb_scale * emb
            saved.append(x)
        if m.crosstransformer:
            if m.bottom_channels:
                f = x.shape[2]
                x = rearrange(x, "b c f t-> b c (f t)")
                x = m.channel_upsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = m.channel_upsampler_t(xt)
            x, xt = self.cross(x, xt)
            if m.bottom_channels:
                x = rearrange(x, "b c f t-> b c (f t)")
                x = m.channel_downsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = m.channel_downsampler_t(xt)
        for idx, decode in enumerate(m.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))
            offset = m.depth - len(m.tdecoder)
            if idx >= offset:
                tdec = m.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip, length_t)
        return x, xt


def snr(reference, estimate):
    return 10 * np.log10(np.sum(reference**2) / max(np.sum((reference - estimate) ** 2), 1e-20))


def main():
    # The attention's fast path is a single fused op Core ML doesn't know.
    torch.backends.mha.set_fastpath_enabled(False)
    model = get_model("htdemucs").models[0].eval()
    model.use_train_segment = False
    print("sources:", model.sources)

    torch.manual_seed(0)
    spectrum = torch.randn(1, 4, BINS, FRAMES)
    wave = torch.randn(1, 2, SAMPLES)
    network = Network(model, spectrum, wave).eval()
    with torch.no_grad():
        program = torch.export.export(network, (spectrum, wave)).run_decompositions({})
        expected = [t.numpy() for t in network(spectrum, wave)]

    mlmodel = ct.convert(
        program,
        inputs=[
            ct.TensorType(name="spectrum", shape=spectrum.shape),
            ct.TensorType(name="wave", shape=wave.shape),
        ],
        outputs=[ct.TensorType(name="spectra"), ct.TensorType(name="waves")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.author = "Meta Platforms (Défossez, Rouard), converted for Liland"
    mlmodel.license = "MIT"
    mlmodel.short_description = (
        "HTDemucs network: normalized stereo spectrogram (4 x 2048 x 44) and wave (2 x 45056) in, "
        "normalized spectra (16 x 2048 x 44) and waves (8 x 45056) of drums, bass, other and vocals out."
    )
    mlmodel.save(OUTPUT)
    # Left over from the export, and nothing in the package refers to it.
    debug = os.path.join(OUTPUT, "executorch_debug_handle_mapping.json")
    if os.path.exists(debug):
        os.remove(debug)
    print("saved", os.path.abspath(OUTPUT))

    gpu = ct.models.MLModel(OUTPUT, compute_units=ct.ComputeUnit.CPU_AND_GPU)
    result = gpu.predict({"spectrum": spectrum.numpy(), "wave": wave.numpy()})
    for name, reference in zip(("spectra", "waves"), expected):
        print(f"{name}: shape {result[name].shape}, Core ML on the GPU vs PyTorch {snr(reference, result[name]):.1f} dB")


if __name__ == "__main__":
    main()
