header
lorom
;##############################
; 複数のオフセットで使われてる奴は面倒だからやめよう
; スプライト系のRAMはぱっと数えただけで 12 * 50 = 0x258 ある。

!itizi_ram = $1DFD	; 2bytes
!itizi_ram2 = $1E00	; 1byte

;##############################
; アドレスだけ変えるもの

; !st_start = $0FBE
; !st_size = $C

; incsrc st.asm

;##############################
; hijackするもの

!Pointer16x = $7EC100
incsrc relocationPatch_0FBE.asm


;##############################
; hijack用の空き領域
!CodeOffset = $108000

!RatsCodeSize = CodeEnd-!CodeOffset-$08
org !CodeOffset
db "STAR"
dw !RatsCodeSize-$01
dw !RatsCodeSize-$01^$FFFF

db "Hello!"

; ここから

incsrc relocationHijack_0FBE.asm

CodeEnd:
	print "pc: ", pc
