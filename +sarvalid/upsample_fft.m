function S_up = upsample_fft(S, grid)
%UPSAMPLE_FFT 使用中心频谱补零完成距离/方位二维带限插值。

S_up = S;
if grid.upsampled_size(1) ~= size(S_up, 1)
    S_up = upsample_dimension(S_up, grid.upsampled_size(1), 1);
end
if grid.upsampled_size(2) ~= size(S_up, 2)
    S_up = upsample_dimension(S_up, grid.upsampled_size(2), 2);
end
end

function output = upsample_dimension(input, target_size, dimension)
current_size = size(input, dimension);
if target_size < current_size
    error('sarvalid:InvalidUpsampleSize', '目标尺寸不能小于当前尺寸。');
end
if target_size == current_size
    output = input;
    return;
end

spectrum = fftshift(fft(input, [], dimension), dimension);
pad_total = target_size - current_size;
pad_before = floor(pad_total / 2);
pad_after = pad_total - pad_before;

if dimension == 1
    output_spectrum = [ ...
        zeros(pad_before, size(input, 2), 'like', spectrum); ...
        spectrum; ...
        zeros(pad_after, size(input, 2), 'like', spectrum)];
else
    output_spectrum = [ ...
        zeros(size(input, 1), pad_before, 'like', spectrum), ...
        spectrum, ...
        zeros(size(input, 1), pad_after, 'like', spectrum)];
end

effective_q = target_size / current_size;
output = ifft(ifftshift(output_spectrum, dimension), [], dimension) * effective_q;
end
