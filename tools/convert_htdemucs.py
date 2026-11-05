"""Converts HTDemucs and HTDemucs 6s (guitar only) to Liland's Core ML models in Liland/Resources.

Setup: python3.11 -m venv venv && venv/bin/pip install torch demucs coremltools
Usage: venv/bin/python tools/convert_htdemucs.py [htdemucs] [htdemucs_6s]
Only the network: spectrograms and normalization run in DemucsSplitter.swift, in single precision.
Checked on the GPU: on the Neural Engine rounding errors ruin near-silent bands (~8 dB vs 49 dB).
"""

import os
import sys

import coremltools as ct
import numpy as np
import torch
import torch.nn.functional as F
from demucs.pretrained import get_model
from demucs.transformer import create_2d_sin_embedding
from einops import rearrange

HOP = 1024
BINS = 2048
RESOURCES = os.path.join(os.path.dirname(__file__), "..", "Liland", "Resources")
# name -> (package, spectrogram frames in); 44 frames is ~1 s, 6s needs twice that for the guitar.
MODELS = {"htdemucs": ("HTDemucs", 44), "htdemucs_6s": ("HTDemucs6s", 88)}


class LayerGroupNorm(torch.nn.Module):
    """GroupNorm as one layer_norm per group plus affine: same numbers, one Core ML op, faster on GPU."""

    def __init__(self, norm):
        super().__init__()
        self.norm = norm
        # Demucs's own GroupNorm normalizes (batch, time, channels) over time and channels.
        self.channels_last = type(norm).__name__ == "MyGroupNorm"

    def forward(self, x):
        norm = self.norm
        if self.channels_last:
            assert norm.num_groups == 1
            return F.layer_norm(x, x.shape[1:], eps=norm.eps) * norm.weight + norm.bias
        shape = x.shape
        groups = x.reshape(shape[0], norm.num_groups, -1)
        x = F.layer_norm(groups, groups.shape[2:], eps=norm.eps).reshape(shape)
        affine = (1, shape[1]) + (1,) * (len(shape) - 2)
        return x * norm.weight.reshape(affine) + norm.bias.reshape(affine)


def replace_group_norms(module):
    for name, child in module.named_children():
        if isinstance(child, torch.nn.GroupNorm):
            setattr(module, name, LayerGroupNorm(child))
        else:
            replace_group_norms(child)


class Network(torch.nn.Module):
    """`HTDemucs.forward` between its normalization and its inverse spectrogram (demucs 4.1.0)."""

    def __init__(self, model, spectrum, wave):
        super().__init__()
        self.model = model
        # Position embeddings use Python shape math Core ML can't follow; shapes are fixed, so precompute.
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


def convert(name, package, frames):
    model = get_model(name).models[0].eval()
    model.use_train_segment = False
    sources = len(model.sources)
    samples = frames * HOP
    print(name, "sources:", model.sources)

    torch.manual_seed(0)
    spectrum = torch.randn(1, 4, BINS, frames)
    wave = torch.randn(1, 2, samples)
    with torch.no_grad():
        expected = [t.numpy() for t in Network(model, spectrum, wave).eval()(spectrum, wave)]
    replace_group_norms(model)
    network = Network(model, spectrum, wave).eval()
    with torch.no_grad():
        program = torch.export.export(network, (spectrum, wave)).run_decompositions({})

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
        f"{name} network: normalized stereo spectrogram (4 x {BINS} x {frames}) and wave (2 x {samples}) in, "
        f"normalized spectra ({4 * sources} x {BINS} x {frames}) and waves ({2 * sources} x {samples}) "
        f"of {', '.join(model.sources)} out."
    )
    output = os.path.join(RESOURCES, f"{package}.mlpackage")
    mlmodel.save(output)
    # Export leftover; nothing in the package refers to it.
    debug = os.path.join(output, "executorch_debug_handle_mapping.json")
    if os.path.exists(debug):
        os.remove(debug)
    print("saved", os.path.abspath(output))

    gpu = ct.models.MLModel(output, compute_units=ct.ComputeUnit.CPU_AND_GPU)
    result = gpu.predict({"spectrum": spectrum.numpy(), "wave": wave.numpy()})
    for output_name, reference in zip(("spectra", "waves"), expected):
        print(f"{output_name}: shape {result[output_name].shape}, Core ML on the GPU vs PyTorch "
              f"{snr(reference, result[output_name]):.1f} dB")


def main():
    # The attention's fast path is a single fused op Core ML doesn't know.
    torch.backends.mha.set_fastpath_enabled(False)
    for name in sys.argv[1:] or MODELS:
        package, frames = MODELS[name]
        convert(name, package, frames)


if __name__ == "__main__":
    main()
