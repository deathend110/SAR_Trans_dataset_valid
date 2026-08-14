function [RC_base, meta] = generate_base_rc(signal, S60, acq_cfg, context)
%GENERATE_BASE_RC 统一完成上采样、阈值、1-bit量化、RC和基网格投影。

arguments
    signal
    S60 (1, 1) struct
    acq_cfg (1, 1) struct
    context (1, 1) struct = struct()
end

if ~ismatrix(signal)
    error('sarvalid:InvalidEcho', '输入必须是二维复回波。');
end
if isreal(signal)
    error('sarvalid:RealEcho', '输入应为包含I/Q信息的复回波。');
end

grid = sarvalid.resolve_acquisition(acq_cfg, size(signal), S60);
signal_up = sarvalid.upsample_fft(signal, grid);
[threshold, threshold_meta] = sarvalid.build_threshold( ...
    signal_up, grid, acq_cfg, S60, context);
channel_1bit = sarvalid.quantize_with_threshold(signal_up, threshold);

tnrn_up = 2 * S60.R0 / S60.C + ...
    ((0:size(signal_up, 1)-1).' - floor(size(signal_up, 1) / 2)) / grid.Fs_up;
RC_up = Range_Compress(channel_1bit, S60.fc, tnrn_up, S60.gama, ...
    S60.R0, S60.C, grid.Fs_up, S60.Tp);

RC_base = RC_up;
if size(RC_base, 2) ~= size(signal, 2)
    RC_base = sarvalid.crop_spectrum(RC_base, size(signal, 2), 2);
end
if size(RC_base, 1) ~= size(signal, 1)
    RC_base = sarvalid.crop_spectrum(RC_base, size(signal, 1), 1);
end

if ~isequal(size(RC_base), size(signal))
    error('sarvalid:BaseRCSizeMismatch', '基网格RC尺寸与输入回波尺寸不一致。');
end

meta = struct();
meta.method = string(acq_cfg.method);
meta.file_key = grid.file_key;
meta.grid = grid;
meta.threshold = threshold_meta;
meta.base_size = size(RC_base);
meta.sigma_scope = "acquisition_block";
end
