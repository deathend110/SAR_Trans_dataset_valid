function [sequence, meta] = generate_hlh_sequence_framewise(seq_signal, S60, pair_cfg, context)
%GENERATE_HLH_SEQUENCE_FRAMEWISE 生成逐帧局部阈值/能量对齐消融结果。

arguments
    seq_signal
    S60 (1, 1) struct
    pair_cfg (1, 1) struct
    context (1, 1) struct = struct()
end

sequence_cfg = pair_cfg.sequence;
mask = sarvalid.build_hlh_mask(sequence_cfg);
num_frames = sequence_cfg.n_frames;
patch_size = sequence_cfg.patch_size;
input_images = zeros(patch_size, patch_size, num_frames, 'single');
gt_images = zeros(patch_size, patch_size, num_frames, 'single');
scale_factors = ones(num_frames, 1);

legacy_master = [];
if isfield(context, "legacy_lcm") && context.legacy_lcm
    legacy_master = build_legacy_range_rt_master(seq_signal, pair_cfg, context);
end

for frame_idx = 1:num_frames
    start_idx = 1 + (frame_idx - 1) * sequence_cfg.step;
    stop_idx = start_idx + sequence_cfg.signal_width - 1;
    signal_frame = seq_signal(:, start_idx:stop_idx);
    frame_mask = [ ...
        repmat(mask.frames(frame_idx, 1), 1, sequence_cfg.valid_margin), ...
        mask.frames(frame_idx, :), ...
        repmat(mask.frames(frame_idx, end), 1, sequence_cfg.valid_margin)];

    frame_context = context;
    % 不显式传入中心索引，使SFT按各自实际上采样宽度建立局部时间原点。
    % 这对BARU尤其重要：其方位维长度通常不等于原始1200列。
    if isfield(frame_context, "slow_time_center_index")
        frame_context = rmfield(frame_context, "slow_time_center_index");
    end
    pair_H = pair_cfg.H;
    pair_L = pair_cfg.L;
    pair_H.seed = pair_cfg.H.seed + frame_idx * 1000;
    pair_L.seed = pair_cfg.L.seed + frame_idx * 1000;

    if ~isempty(legacy_master)
        frame_context_H = frame_context;
        frame_context_L = frame_context;
        frame_context_H.threshold_override = legacy_override( ...
            legacy_master, pair_H.q_total, sequence_cfg.signal_width);
        frame_context_L.threshold_override = legacy_override( ...
            legacy_master, pair_L.q_total, sequence_cfg.signal_width);
    else
        frame_context_H = frame_context;
        frame_context_L = frame_context;
    end

    [RC_H, ~] = sarvalid.generate_base_rc(signal_frame, S60, pair_H, frame_context_H);
    [RC_L, ~] = sarvalid.generate_base_rc(signal_frame, S60, pair_L, frame_context_L);
    [RC_mix, mix_info] = sarvalid.align_and_mix_rc( ...
        RC_H, RC_L, frame_mask, sequence_cfg.energy_buffer);
    scale_factors(frame_idx) = mix_info.scale_factor;
    input_images(:, :, frame_idx) = single( ...
        sarvalid.focus_base_rc(RC_mix, S60, patch_size));
    gt_images(:, :, frame_idx) = single( ...
        sarvalid.generate_gt_image(signal_frame, S60, patch_size));
end

sequence = struct("input_raw", input_images, "gt_raw", gt_images, ...
    "frame_masks", mask.frames, "h_ratio", mask.h_ratio);
meta = struct("protocol", "framewise_legacy_style", ...
    "scale_factors", scale_factors, "legacy_lcm", ~isempty(legacy_master));
end

function master = build_legacy_range_rt_master(seq_signal, pair_cfg, context)
if string(pair_cfg.H.method) ~= "Range_RT" || ...
        string(pair_cfg.L.method) ~= "Range_RT" || ...
        abs(pair_cfg.H.q_total - 2.5) > 1e-12 || ...
        abs(pair_cfg.L.q_total - 1.5) > 1e-12
    error('sarvalid:LegacyLCMUnsupported', ...
        'LCM master threshold仅支持Range_RT (2.5,1.5)。');
end
q_lcm = 7.5;
nr_master = round(q_lcm * size(seq_signal, 1));
Sf = fftshift(fft(seq_signal, [], 1), 1);
pad_total = nr_master - size(seq_signal, 1);
pad_top = floor(pad_total / 2);
Sf_up = [zeros(pad_top, size(seq_signal, 2), 'like', Sf); Sf; ...
    zeros(pad_total-pad_top, size(seq_signal, 2), 'like', Sf)];
signal_master = ifft(ifftshift(Sf_up, 1), [], 1) * q_lcm;
sigma = sqrt(2 / pi) * mean(abs(signal_master(:)));
seed = pair_cfg.H.seed;
if isfield(context, "legacy_seed")
    seed = context.legacy_seed;
end
stream = RandStream("mt19937ar", "Seed", seed);
phi = 2 * pi * rand(stream, nr_master, 1);
master = pair_cfg.H.threshold.As * sigma * exp(1i * phi);
end

function U = legacy_override(master, q, width)
q_lcm = 7.5;
stride = q_lcm / q;
if abs(stride - round(stride)) > 1e-12
    error('sarvalid:LegacyLCMStride', 'LCM阈值抽样步长不是整数。');
end
column = master(1:round(stride):end);
U = repmat(column, 1, width);
end
