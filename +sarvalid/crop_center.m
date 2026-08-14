function patch = crop_center(image, patch_size)
%CROP_CENTER 从二维图像中心裁出指定正方形区域。

[height, width] = size(image);
if patch_size > height || patch_size > width
    error('sarvalid:CropTooLarge', '中心裁剪尺寸超过输入图像。');
end
row_start = floor((height - patch_size) / 2) + 1;
col_start = floor((width - patch_size) / 2) + 1;
patch = image(row_start:row_start+patch_size-1, ...
    col_start:col_start+patch_size-1);
end
