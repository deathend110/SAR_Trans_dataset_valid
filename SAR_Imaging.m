function SAR_image=SAR_Imaging(echo_RCMC_tr_ta,lambda,Fs,R0,c,v,tnan,Ta,PRF)
[nrn,nan]=size(echo_RCMC_tr_ta);
deltaR=c/2/Fs;
Rscal=((-nrn/2:nrn/2-1).'*deltaR);
kar=-2*v*v./lambda./(Rscal+R0); %% 

Ha=zeros(nrn,nan);
Haa=exp(-1i*pi*kar*(tnan(-fix(Ta*PRF)/2+nan/2+1:fix(Ta*PRF)/2+nan/2)).^2);
Ha(:,-fix(Ta*PRF)/2+nan/2+1:fix(Ta*PRF)/2+nan/2)=Haa;
RD_tr_fa=fftshift(fft(fftshift(echo_RCMC_tr_ta,2),[],2),2).*(fftshift(fft(fftshift(Ha,2),[],2),2));
SAR_image=fftshift(ifft(fftshift(RD_tr_fa,2),[],2),2);