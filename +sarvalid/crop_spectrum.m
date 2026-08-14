function X_crop = crop_spectrum(X, target_size, dimension)
%CROP_SPECTRUM 在指定方向裁剪中心频谱并返回目标网格。

current_size = size(X, dimension);
if target_size > current_size
    error('sarvalid:InvalidCropSize', '目标频谱尺寸不能大于当前尺寸。');
end
if target_size == current_size
    X_crop = X;
    return;
end

Xf = fftshift(fft(X, [], dimension), dimension);
center_idx = floor(current_size / 2) + 1;
half_width = floor(target_size / 2);
if mod(target_size, 2) == 0
    indices = center_idx-half_width:center_idx+half_width-1;
else
    indices = center_idx-half_width:center_idx+half_width;
end

if dimension == 1
    Xf = Xf(indices, :);
else
    Xf = Xf(:, indices);
end
X_crop = ifft(ifftshift(Xf, dimension), [], dimension);
end
