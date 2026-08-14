function [sequence, meta] = generate_hlh_sequence(seq_signal, S60, pair_cfg, context)
%GENERATE_HLH_SEQUENCE 在连续全块RC域生成9帧H/L/H序列。

arguments
    seq_signal
    S60 (1, 1) struct
    pair_cfg (1, 1) struct
    context (1, 1) struct = struct()
end

sequence_cfg = pair_cfg.sequence;
expected_size = [sequence_cfg.signal_height, sequence_cfg.block_width];
if ~isequal(size(seq_signal), expected_size)
    error('sarvalid:SequenceEchoSize', ...
        '连续回波块尺寸应为%s，实际为%s。', ...
        mat2str(expected_size), mat2str(size(seq_signal)));
end

mask = sarvalid.build_hlh_mask(sequence_cfg);
base_context = context;

[RC_H, meta_H] = sarvalid.generate_base_rc(seq_signal, S60, pair_cfg.H, base_context);
[RC_L, meta_L] = sarvalid.generate_base_rc(seq_signal, S60, pair_cfg.L, base_context);
[RC_mix, mix_info] = sarvalid.align_and_mix_rc( ...
    RC_H, RC_L, mask.full, sequence_cfg.energy_buffer);

num_frames = sequence_cfg.n_frames;
patch_size = sequence_cfg.patch_size;
input_images = zeros(patch_size, patch_size, num_frames, 'single');
gt_images = zeros(patch_size, patch_size, num_frames, 'single');

for frame_idx = 1:num_frames
    start_idx = 1 + (frame_idx - 1) * sequence_cfg.step;
    stop_idx = start_idx + sequence_cfg.signal_width - 1;
    RC_frame = RC_mix(:, start_idx:stop_idx);
    signal_frame = seq_signal(:, start_idx:stop_idx);
    input_images(:, :, frame_idx) = single( ...
        sarvalid.focus_base_rc(RC_frame, S60, patch_size));
    gt_images(:, :, frame_idx) = single( ...
        sarvalid.generate_gt_image(signal_frame, S60, patch_size));
end

sequence = struct();
sequence.input_raw = input_images;
sequence.gt_raw = gt_images;
sequence.frame_masks = mask.frames;
sequence.h_ratio = mask.h_ratio;

meta = struct();
meta.protocol = "sequence_global";
meta.H = meta_H;
meta.L = meta_L;
meta.mix = mix_info;
meta.mask = mask;
meta.rc_mix = [];
if isfield(context, "return_rc_mix") && context.return_rc_mix
    meta.rc_mix = RC_mix;
end
end
