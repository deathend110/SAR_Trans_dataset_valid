function values = joint_hl_pixel_pool(h_values, l_values)
%JOINT_HL_PIXEL_POOL 将同尺寸H/L幅度图按像素数等权连接为列向量。

if ~isequal(size(h_values), size(l_values))
    error('sarvalid:JointHLPixelPoolSizeMismatch', ...
        'H和L必须具有完全相同的尺寸。');
end
if ~isreal(h_values) || ~isreal(l_values)
    error('sarvalid:JointHLPixelPoolComplex', ...
        'JointHL分位数只能统计成像后的实数幅度。');
end
values = [single(h_values(:)); single(l_values(:))];
end
