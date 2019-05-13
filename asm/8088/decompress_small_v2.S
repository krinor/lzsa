;  decompress_small.S - space-efficient decompressor implementation for 8088
;
;  Copyright (C) 2019 Emmanuel Marty
;
;  This software is provided 'as-is', without any express or implied
;  warranty.  In no event will the authors be held liable for any damages
;  arising from the use of this software.
;
;  Permission is granted to anyone to use this software for any purpose,
;  including commercial applications, and to alter it and redistribute it
;  freely, subject to the following restrictions:
;
;  1. The origin of this software must not be misrepresented; you must not
;     claim that you wrote the original software. If you use this software
;     in a product, an acknowledgment in the product documentation would be
;     appreciated but is not required.
;  2. Altered source versions must be plainly marked as such, and must not be
;     misrepresented as being the original software.
;  3. This notice may not be removed or altered from any source distribution.

   segment .text
   bits 16

;  ---------------------------------------------------------------------------
;  Decompress raw LZSA2 block
;  inputs:
;  * ds:si: raw LZSA2 block
;  * es:di: output buffer
;  output:
;  * ax:    decompressed size
;  ---------------------------------------------------------------------------

lzsa2_decompress:
   push di                 ; remember decompression offset
   cld                     ; make string operations (lods, movs, stos..) move forward

   xor cx,cx
   mov bx,0100H
   xor bp,bp

.decode_token:
   mov ax,cx               ; clear ah - cx is zero from above or from after rep movsb in .copy_match
   lodsb                   ; read token byte: XYZ|LL|MMMM
   mov dx,ax               ; keep token in dl
   
   and al,018H             ; isolate literals length in token (LL)
   mov cl,3
   shr al,cl               ; shift literals length into place

   cmp al,03H              ; LITERALS_RUN_LEN_V2?
   jne .got_literals       ; no, we have the full literals count from the token, go copy

   call .get_nibble        ; get extra literals length nibble
   add al,cl               ; add len from token to nibble 
   cmp al,012H             ; LITERALS_RUN_LEN_V2 + 15 ?
   jne .got_literals       ; if not, we have the full literals count, go copy

   lodsb                   ; grab extra length byte
   test al,al              ; zero?
   jne .got_literals       ; if not, we have the full literals count, go copy

   lodsw                   ; grab 16-bit extra length

.got_literals:
   xchg cx,ax
   rep movsb               ; copy cx literals from ds:si to es:di

   test dl,dl              ; check match offset mode in token (X bit)
   js .rep_match_or_large_offset

   cmp dl,040H             ; check if this is a 5 or 9-bit offset (Y bit)
   jnb .offset_9_bit

                           ; 5 bit offset
   xchg ax,cx              ; clear ah - cx is zero from the rep movsb above
   mov al,020H             ; shift Z (offset bit 4) in place
   and al,dl
   shr al,1
   call .get_nibble        ; get nibble for offset bits 0-3
   or al,cl                ; merge nibble
   or al,0E0H              ; set offset bits 7-5 to 1
   dec ah                  ; set offset bits 15-8 to 1
   jmp short .get_match_length

.offset_9_bit:             ; 9 bit offset
   xchg ax,cx              ; clear ah - cx is zero from the rep movsb above
   lodsb                   ; get 8 bit offset from stream in A
   dec ah                  ; set offset bits 15-8 to 1
   test dl,020H            ; test bit Z (offset bit 8)
   jne .get_match_length
   dec ah                  ; clear bit 8 if Z bit is clear
   jmp short .get_match_length

.rep_match_or_large_offset:
   cmp dl,0c0H             ; check if this is a 13-bit offset or a 16-bit offset/rep match (Y bit)
   jnb .rep_match_or_16_bit

                           ; 13 bit offset
   lodsb                   ; load match offset bits 0-7

   mov ah,020H             ; shift Z (offset bit 12) in place
   and ah,dl
   shr ah,1
   call .get_nibble        ; get nibble for offset bits 8-11
   or ah,cl                ; merge nibble
   or ah,0E0H              ; set offset bits 15-13 to 1
   sub ah,2                ; substract 512
   jmp short .get_match_length

.rep_match_or_16_bit:
   test dl,020H            ; test bit Z (offset bit 8)
   jne .repeat_match       ; rep-match

                           ; 16 bit offset
   lodsw                   ; Get 2-byte match offset

.get_match_length:
   mov bp,ax               ; bp: offset
.repeat_match:
   mov ax,dx               ; ax: original token
   and al,07H              ; isolate match length in token (MMM)
   add al,2                ; add MIN_MATCH_SIZE_V2

   cmp al,09H              ; MIN_MATCH_SIZE_V2 + MATCH_RUN_LEN_V2?
   jne .got_matchlen       ; no, we have the full match length from the token, go copy

   call .get_nibble        ; get extra literals length nibble
   add al,cl               ; add len from token to nibble 
   cmp al,018H             ; MIN_MATCH_SIZE_V2 + MATCH_RUN_LEN_V2 + 15?
   jne .got_matchlen       ; no, we have the full match length from the token, go copy

   lodsb                   ; grab extra length byte
   test al,al              ; zero?
   jne .got_matchlen       ; if not, we have the entire length

   lodsw                   ; grab 16-bit length
   test ax,ax              ; bail if we hit EOD
   je short .done_decompressing 

.got_matchlen:
   xchg cx,ax              ; copy match length into cx
   push ds                 ; save ds:si (current pointer to compressed data)
   xchg si,ax          
   push es
   pop ds
   mov si,di               ; ds:si now points at back reference in output data
   add si,bp
   rep movsb               ; copy match
   xchg si,ax              ; restore ds:si
   pop ds
   jmp .decode_token       ; go decode another token

.done_decompressing:
   pop ax                  ; retrieve the original decompression offset
   xchg ax,di              ; compute decompressed size
   sub ax,di
   ret                     ; done

.get_nibble:
   neg bh                  ; nibble ready?
   jns .has_nibble
   
   xchg bx,ax
   lodsb                   ; load two nibbles
   xchg ax,bx

.has_nibble:
   mov cl,4                ; swap 4 high and low bits of nibble
   ror bl,cl
   mov cl,0FH
   and cl,bl
   ret