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
         qt-mods->meta-down?
         qt-mods->alt-down?
         qt-mods->mod4-down?
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

;; Modifier flags as Racket's key-event% sees them.  On X11 (the Unix
;; backends), Racket's convention -- gtk/window.rkt -- is: the Alt key is
;; mod1 = meta-down (DrRacket's `m:` bindings), the Super/Win key is mod4, and
;; alt-down is the (unused) GDK_META_MASK.  On macOS/Windows Qt's Alt/Meta map
;; straight through (Cmd = Qt::Meta on macOS since AA_MacDontSwapCtrlAndMeta).
(define (unix-platform? platform) (eq? platform 'unix))
(define (qt-mods->meta-down? m [platform (system-type)])
  (if (unix-platform? platform) (qt-mods->alt? m) (qt-mods->meta? m)))
(define (qt-mods->alt-down? m [platform (system-type)])
  (if (unix-platform? platform) #f (qt-mods->alt? m)))
(define (qt-mods->mod4-down? m [platform (system-type)])
  (and (unix-platform? platform) (qt-mods->meta? m)))

; Map Qt::Key (int) → Racket key symbol or char.
; Returns #f for keys Racket does not report (caller drops the event).
;
; Qt's text() is a control character (Ctrl+A -> 0x01) or empty whenever Ctrl
; is held, so text alone loses every Ctrl+<printable> chord (Block D §1.1).
; The fallback derives the char from key() instead: Qt reports letters as the
; upper-case Key_A..Key_Z and other printables as their (shift-resolved)
; character, which is what gtk's keyval delivers -- letters lower-case unless
; Shift is held.  Measured values: tests/key-map.rkt, docs/2026-09-30_report-linux.md.
(define (qt-key->racket-keycode key text-char [mods 0]
                                #:platform [platform (system-type)])
  (cond
    ; Printable: use the text character if available
    [(and (not (zero? text-char))
          (>= text-char 32)
          (not (= text-char 127)))       ; exclude DEL
     (integer->char text-char)]

    ; Special key table
    [(= key #x01000000) 'escape]
    [(= key #x01000001) #\tab]
    [(= key #x01000002) #\tab]           ; Key_Backtab (Shift+Tab); gtk: 0xfe20 -> #\tab
    [(= key #x01000003) #\backspace]
    [(= key #x01000004) #\return]
    [(= key #x01000005) #\return]        ; Key_Enter (numpad)
    [(= key #x01000006) 'insert]
    [(= key #x01000007) #\rubout]        ; Delete (racket/gui: #\rubout, not 'delete)
    [(= key #x01000008) 'pause]
    [(= key #x01000010) 'home]
    [(= key #x01000011) 'end]
    [(= key #x01000012) 'left]
    [(= key #x01000013) 'up]
    [(= key #x01000014) 'right]
    [(= key #x01000015) 'down]
    [(= key #x01000016) 'prior]          ; Page Up
    [(= key #x01000017) 'next]           ; Page Down
    ; Modifier keys themselves.  gtk reports only Shift/Control presses;
    ; Alt/Meta(Super)/AltGr are dropped there, so drop them on Unix as well.
    [(= key #x01000020) 'shift]
    [(= key #x01000021) 'control]
    [(= key #x01000022) (if (unix-platform? platform) #f 'start)]  ; Meta / Windows key
    [(= key #x01000023) (if (unix-platform? platform) #f 'menu)]   ; Alt
    [(= key #x01000024) 'capital]        ; Caps Lock
    [(= key #x01000055) 'menu]           ; Key_Menu (context-menu key)
    ; F-keys: Qt::Key_F1..F24 = 0x01000030..0x01000047
    [(and (>= key #x01000030) (<= key #x01000047))
     (string->symbol
      (string-append "f" (number->string (+ 1 (- key #x01000030)))))]
    ; Space
    [(= key #x20) #\space]
    ; Printable key whose text() was a control char / empty (Ctrl held).
    [(and (> key #x20) (< key #x7f))
     (if (and (>= key #x41) (<= key #x5a))
         (integer->char (if (qt-mods->shift? mods) key (+ key 32)))
         (integer->char key))]
    ; Fallback: unknown special key
    [else #f]))
