function y = normalize_image(x)
% 归一化图像到[0,1]
mag = abs(x);
peak = max(mag(:));
if peak == 0
    y = mag;
else
    y = mag / peak;
end
end
