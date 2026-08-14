function gt180 = generate_gt_180_sequence(manifest_row, S180, sequence_cfg)
%GENERATE_GT_180_SEQUENCE 为一条连续序列生成9帧共同网格180 MHz GT。

signal180 = sarvalid.load_echo_block_180( ...
    manifest_row, S180, sequence_cfg.block_width);
gt180 = zeros(sequence_cfg.patch_size, sequence_cfg.patch_size, ...
    sequence_cfg.n_frames, 'single');
for frame_idx = 1:sequence_cfg.n_frames
    start_idx = 1 + (frame_idx - 1) * sequence_cfg.step;
    stop_idx = start_idx + sequence_cfg.signal_width - 1;
    gt180(:, :, frame_idx) = single(sarvalid.generate_gt_180_image( ...
        signal180(:, start_idx:stop_idx), S180, sequence_cfg.patch_size));
end
end
