#lang racket/base
; Qt key code → Racket key-event% key-code mapping.
;
; Qt::Key values >= 0x01000000 are special (non-printable) keys.
; Values < 0x01000000 are printable and handled via text_char.
;
; Racket key-codes: char for printable, symbol for special.
; Reference: racket/gui key-event% docs, win32/key.rkt, gtk/window.rkt.
(provide qt-key->racket-keycode
         qt-mods->shift?
         qt-mods->control?
         qt-mods->meta?
         qt-mods->alt?
         qt-buttons->left?
         qt-buttons->middle?
         qt-buttons->right?)

; Qt modifier bitmask (from shim.cpp encodeMods):
;   Shift=1, Ctrl=2, Alt=4, Meta(Win)=8
(define (qt-mods->shift?   m) (not (zero? (bitwise-and m 1))))
(define (qt-mods->control? m) (not (zero? (bitwise-and m 2))))
(define (qt-mods->alt?     m) (not (zero? (bitwise-and m 4))))
(define (qt-mods->meta?    m) (not (zero? (bitwise-and m 8))))

; Qt button bitmask (from shim.cpp encodeButtons):
;   Left=1, Middle=2, Right=4
(define (qt-buttons->left?   b) (not (zero? (bitwise-and b 1))))
(define (qt-buttons->middle? b) (not (zero? (bitwise-and b 2))))
(define (qt-buttons->right?  b) (not (zero? (bitwise-and b 4))))

; Map Qt::Key (int) → Racket key symbol or char.
; Returns #f for unknown special keys (caller should fall back to text_char).
(define (qt-key->racket-keycode key text-char)
  (cond
    ; Printable: use the text character if available
    [(and (not (zero? text-char))
          (>= text-char 32)
          (not (= text-char 127)))       ; exclude DEL
     (integer->char text-char)]

    ; Special key table
    [(= key #x01000000) 'escape]
    [(= key #x01000001) #\tab]
    [(= key #x01000003) #\backspace]
    [(= key #x01000004) #\return]
    [(= key #x01000005) #\return]        ; Key_Enter (numpad)
    [(= key #x01000006) 'insert]
    [(= key #x01000007) 'delete]
    [(= key #x01000008) 'pause]
    [(= key #x01000010) 'home]
    [(= key #x01000011) 'end]
    [(= key #x01000012) 'left]
    [(= key #x01000013) 'up]
    [(= key #x01000014) 'right]
    [(= key #x01000015) 'down]
    [(= key #x01000016) 'prior]          ; Page Up
    [(= key #x01000017) 'next]           ; Page Down
    ; Modifier keys themselves
    [(= key #x01000020) 'shift]
    [(= key #x01000021) 'control]
    [(= key #x01000022) 'start]          ; Meta / Windows key
    [(= key #x01000023) 'menu]           ; Alt
    [(= key #x01000024) 'capital]        ; Caps Lock
    ; F-keys: Qt::Key_F1..F24 = 0x01000030..0x01000047
    [(and (>= key #x01000030) (<= key #x01000047))
     (string->symbol
      (string-append "f" (number->string (+ 1 (- key #x01000030)))))]
    ; Space
    [(= key #x20) #\space]
    ; Fallback: unknown special key
    [else #f]))
