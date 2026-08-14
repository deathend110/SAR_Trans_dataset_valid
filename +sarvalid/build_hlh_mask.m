function mask = build_hlh_mask(sequence_cfg)
%BUILD_HLH_MASK 构造2224列全块掩膜及九帧512列局部掩膜。

arguments
    sequence_cfg (1, 1) struct
end

if sequence_cfg.logic_length ~= 1536 || sequence_cfg.patch_size ~= 512 || ...
        sequence_cfg.n_frames ~= 9 || sequence_cfg.step ~= 128
    error('sarvalid:UnsupportedSequenceGeometry', ...
        '当前H/L/H协议固定为1536有效列、512 patch、9帧和128步长。');
end

logic = false(1, sequence_cfg.logic_length);
logic(1:512) = true;
logic(1025:1536) = true;
full_mask = [ ...
    repmat(logic(1), 1, sequence_cfg.valid_margin), ...
    logic, ...
    repmat(logic(end), 1, sequence_cfg.valid_margin)];
if numel(full_mask) ~= sequence_cfg.block_width
    error('sarvalid:SequenceMaskLength', '全块H/L/H掩膜长度不正确。');
end

frame_masks = false(sequence_cfg.n_frames, sequence_cfg.patch_size);
for frame_idx = 1:sequence_cfg.n_frames
    start_idx = 1 + (frame_idx - 1) * sequence_cfg.step;
    frame_masks(frame_idx, :) = logic(start_idx:start_idx+sequence_cfg.patch_size-1);
end

mask = struct();
mask.logic = logic;
mask.full = full_mask;
mask.frames = frame_masks;
mask.h_ratio = mean(frame_masks, 2);
mask.boundaries = find(diff(full_mask) ~= 0);
end
