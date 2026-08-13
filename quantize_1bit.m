function y = quantize_1bit(x)
% QUANTIZE_1BIT  Sign quantization of a complex matrix (range x azimuth).
%   y has real and imaginary parts in {-1, +1}.

re = sign(real(x));
im = sign(imag(x));
% Map zeros to +1 to avoid losing energy on purely zero samples.
re(re == 0) = 1;
im(im == 0) = 1;
y = re + 1i * im;
end
