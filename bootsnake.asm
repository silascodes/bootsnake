; 16 bit assembly, should be loaded by BIOS at address 0x7c00
BITS 16
ORG 0x7c00



; -----------------------------------------------------------------------------
; Constant definitions
; Define handy constants to make life easier!
; -----------------------------------------------------------------------------

; Game timing controls, see PIT documentation for more info
; If you want 10 FPS for example, set PIT_TICKS to 20 and GAME_TICKS to 2
%define PIT_OSC_FREQ    1193182
%define PIT_TICKS       20      ; This can't be lower than 18
%define PIT_FREQUENCY   PIT_OSC_FREQ / PIT_TICKS
%define GAME_TICKS      10

; Screen size definitions (for VGA mode 0, 40x25 16 color text mode)
%define SCREEN_WIDTH    40
%define SCREEN_HEIGHT   25
%define SCREEN_CELLS    SCREEN_WIDTH * SCREEN_HEIGHT
%define SCREEN_BYTES    SCREEN_CELLS * 2
%define FRONT_BUF_SEG   0xb800

; PRNG related defines
%define RANDOM_S        0xb5ad4eceda1ce2a9

; Game display related defines
%define FRAME_CHAR      0xDB
%define FRAME_ATTR      0x07
%define FOOD_CHAR       0x40
%define FOOD_ATTR       0x04

; Gameplay related defines
%define FOOD_MAX        3



; -----------------------------------------------------------------------------
; Initialisation sequence
; Get hardware we need into correct state, enable interrupts, enter busy loop
; -----------------------------------------------------------------------------

; Make sure interrupts are disabled for now
cli

; Set up the stack
mov ax, 0x1000  ; Segment after CS
mov ss, ax
mov sp, 0xfff0

; Initialise and set up the PICs
mov al, 0x11
out 0x20, al
out 0xa0, al
mov al, 0x04
out 0x21, al    ; Master PIC has slave on IRQ2
mov al, 0x02
out 0xa1, al    ; Slave PIC cascade mode
mov al, 0x01
out 0x21, al
out 0xa1, al

; Clear PIC masks
mov al, 0xfc    ; Only care about timer and keyboard interrupts
out 0x21, al
mov al, 0xff    ; Don't care about any of these interrupts
out 0xa1, al

; Install handler for IRQ0 (timer)
mov word [0x00], OnTimer
mov [0x02], cs

; Install handler for IRQ1 (keyboard)
mov word [0x04], OnKeyboard
mov [0x06], cs

; Set up the PIT channel 0 for controlling game speed and timing
mov al, 0x36
out 0x43, al
mov ax, PIT_FREQUENCY
out 0x40, al
mov al, ah
out 0x40, al

; Enable interrupts
sti

; Initialise video mode (use VGA 40x20 16 colour mode)
xor ax, ax
int 0x10

; Disable VGA cursor
mov ah, 0x01
mov ch, 0x20    ; Invisible cursor mode
mov cl, 0x00    ; Don't care, it's invisible
int 0x10

; Set GS as frame buffer Segment
mov ax, FRONT_BUF_SEG
mov gs, ax

; Draw the stuff that never changes
call DrawFrame

; Go into a busy loop to wait for an interrupt
busyLoop:
    jmp busyLoop



; -----------------------------------------------------------------------------
; OnTimer
; ISR for timer interrupts, regulates frame rate and calls gameTick
; -----------------------------------------------------------------------------

OnTimer:
    pusha
    mov al, [tickCount]
    dec al
    jz _callGameTick
    mov byte [tickCount], al
    jmp _skipGameTick
_callGameTick:
    mov byte [tickCount], GAME_TICKS
    call GameTick
_skipGameTick:
    ;mov al, 61h
    ;out 20h, al
    popa
    iret



; -----------------------------------------------------------------------------
; OnKeyboard
; ISR for keyboard interrupts
; -----------------------------------------------------------------------------
OnKeyboard:
    pusha
    ;in al, 60h
    ;test al, 80h
    ;jnz _onKeyboardSkip
    ; TODO: do stuff
_onKeyboardSkip:
    ;mov al, 61h
    ;out 20h, al
    popa
    iret



; -----------------------------------------------------------------------------
; GameTick
; Called for each game update
; -----------------------------------------------------------------------------

GameTick:
    call SpawnFood
    ret



; -----------------------------------------------------------------------------
; SpawnFood
; Spawn more food if there is less than FOOD_MAX food currently spawned
; -----------------------------------------------------------------------------

SpawnFood:
    pusha

_spawnFoodLoop:
    ; If we have FOOD_MAX food alive currently, we're done
    cmp byte [currentFood], FOOD_MAX
    je _spawnFoodDone

_spawnFoodPosLoop:
    ; Generate random x coordinate
    call Random
    mov bl, (SCREEN_WIDTH - 2)
    div bl
    mov dl, ah

    ; Generate random y coordinate
    call Random
    mov bl, (SCREEN_HEIGHT - 3)
    div bl
    mov dh, ah

    ; Check tile is free
    mov bl, dl
    mov bh, dh
    call IsTileFree
    cmp ax, 0
    je _spawnFoodPosLoop

    ; Draw the food
    mov al, FOOD_CHAR
    mov ah, FOOD_ATTR
    call DrawPoint

    ; Increment food count and loop
    inc byte [currentFood]
    jmp _spawnFoodLoop

_spawnFoodDone:

    popa
    ret



; -----------------------------------------------------------------------------
; IsTileFree
; Check if the given tile is within play area and free from snake or food
; Parameters:
;   bl      x coordinate
;   bh      y coordinate
; Returns:
;   ax      0 = tile used, 1 = tile free
; -----------------------------------------------------------------------------

IsTileFree:
    xor ax, ax
    call CalculateScreenOffset
    cmp word [gs:di], 0x0000
    jne _isTileFreeDone
    inc ax
_isTileFreeDone:
    ret



; -----------------------------------------------------------------------------
; Random
; Generate a pseudo-random number
; Based on the "Middle Square Weyl Sequence PRNG" example from
; https://en.wikipedia.org/wiki/Middle-square_method
; Returns:
;   ax      pseudo-random number
; -----------------------------------------------------------------------------

Random:
    push bx

    mov ax, [randomX]
    mul ax

    mov bx, [randomW]
    add bx, RANDOM_S

    add ax, bx
    mov bx, ax

    shl ax, 32
    shr bx, 32

    or ax, bx

    pop bx
    ret



; -----------------------------------------------------------------------------
; DrawFrame
; Draws the frame around the outside of the play area
; -----------------------------------------------------------------------------

DrawFrame:
    pusha
    
    ; Set character and attributes for frame lines
    mov al, FRAME_CHAR
    mov ah, FRAME_ATTR

    ; Draw top line
    mov bl, 0
    mov bh, 1
    mov cx, (SCREEN_WIDTH - 1)
    call DrawHorizontalLine

    ; Draw bottom line
    mov bh, (SCREEN_HEIGHT - 1)
    call DrawHorizontalLine

    ; Draw left line
    mov bh, 1
    mov cx, (SCREEN_HEIGHT - 2)
    call DrawVerticalLine

    ; Draw right line
    mov bl, (SCREEN_WIDTH - 1)
    call DrawVerticalLine

    ; Draw game name
    lea si, [gameName]
    mov ah, 0x0f
    xor bx, bx
    call DrawString

    ; Draw score text
    lea si, [scoreText]
    mov bl, 29
    call DrawString

    popa
    ret



; -----------------------------------------------------------------------------
; DrawPoint
; Draws a point, does not do any bounds checking
; Parameters:
;   al      character to draw
;   ah      character attributes
;   bl      x coordinate
;   bh      y coordinate
; -----------------------------------------------------------------------------

DrawPoint:
    call CalculateScreenOffset
    mov word [gs:di], ax
    ret



; -----------------------------------------------------------------------------
; DrawString
; Draws a null terminated string, does not do any destination bounds checking
; Parameters:
;   ah      character attributes
;   bl      starting x coordinate
;   bh      y coordinate
;   si      memory address of string
; -----------------------------------------------------------------------------

DrawString:
    pusha

    ; Loop over string until we hit null, call DrawPoint to draw each character
_drawStringLoop:
    cmp byte [si], 0
    je _drawStringDone
    mov al, [si]
    call DrawPoint
    inc bl
    inc si
    jmp _drawStringLoop
_drawStringDone:

    popa
    ret



; -----------------------------------------------------------------------------
; DrawHorizontalLine
; Draw a horizontal line, does not do any bounds checking
; Parameters:
;   al      character to draw
;   ah      character attributes
;   bl      starting x coordinate
;   bh      starting y coordinate
;   cx      length
; -----------------------------------------------------------------------------

DrawHorizontalLine:
    pusha

    ; Get starting address in back buffer
    call CalculateScreenOffset

    ; Do actual line drawing
_drawHorizontalLineLoop:
    mov word [gs:di], ax
    add di, 2
    dec cx
    cmp cx, 0
    jge _drawHorizontalLineLoop
    
    popa
    ret


; -----------------------------------------------------------------------------
; DrawVerticalLine
; Draw a vertical line, does not do any bounds checking
; Parameters:
;   al      character to draw
;   ah      character attributes
;   bl      starting x coordinate
;   bh      starting y coordinate
;   cx      length
; -----------------------------------------------------------------------------

DrawVerticalLine:
    pusha

    ; Get starting address in back buffer
    call CalculateScreenOffset

    ; Do actual line drawing
_drawVerticalLineLoop:
    mov word [gs:di], ax
    add di, (SCREEN_WIDTH * 2)
    dec cx
    cmp cx, 0
    jge _drawVerticalLineLoop
    
    popa
    ret



; -----------------------------------------------------------------------------
; CalculateScreenOffset
; Calculates the offset into the frame buffer for the given x,y coordinates
; Parameters:
;   bl      x coordinate
;   bh      y coordinate
; Returns:
;   di      offset into frame buffer
; -----------------------------------------------------------------------------

CalculateScreenOffset:
    ; Clear offset
    xor di, di
    
    ; If y coordinate is greater than 0, advance offset down screen
    cmp bh, 0
    je _drawPointSkipYAdvance
    mov di, (SCREEN_WIDTH * 2)
    push ax
    mov ax, di
    mul bh
    mov di, ax
    pop ax
_drawPointSkipYAdvance:

    ; If x coordinate is greater than 0, advance offset across screen
    cmp bl, 0
    je _drawPointSkipXAdvance
    push bx
    xor bh, bh
    add di, bx
    add di, bx
    pop bx
_drawPointSkipXAdvance:
    ret



; -----------------------------------------------------------------------------
; Variable definitions
; Define some variables we will need for the game
; -----------------------------------------------------------------------------

gameName:       db 'BootSnake', 0
scoreText:      db 'Score: ', 0
tickCount:      db GAME_TICKS
randomX:        db 0
randomW:        db 0
score:          db 0
currentFood:    db 0



; -----------------------------------------------------------------------------
; Boot sector magic
; Add boot sector signature and pad with zero so binary is exactly 512 bytes
; -----------------------------------------------------------------------------

TIMES 510 - ($ - $$) db 0
dw 0xaa55
