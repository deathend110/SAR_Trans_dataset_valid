function Range_Com_tr_ta=Range_Compress(echo,fc,tnrn,gama,R0,c,Fs,Tp)
[nrn,nan]=size(echo);
x=(echo);%.*(exp(-1i*2*pi*fc*tnrn).*ones(1,nan));
Hr=zeros(nrn,nan);
Hrr=exp(1i*pi*gama*(tnrn(-fix(Tp*Fs)/2+nrn/2+1:fix(Tp*Fs)/2+nrn/2)-2*R0/c).^2)*ones(1,nan);
Hr(-fix(Tp*Fs)/2+nrn/2+1:fix(Tp*Fs)/2+nrn/2,:)=Hrr;
Comp_fr_ta=fftshift(fft(fftshift(x,1),[],1),1).*conj(fftshift(fft(fftshift(Hr,1),[],1),1));
Range_Com_tr_ta=fftshift(ifft(fftshift(Comp_fr_ta,1),[],1),1);