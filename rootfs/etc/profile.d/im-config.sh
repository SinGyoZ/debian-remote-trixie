# fcitx5 输入法环境（xrdp 会话经 startwm.sh → /etc/X11/Xsession → /etc/profile 加载）
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
