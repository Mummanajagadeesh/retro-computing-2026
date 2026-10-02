10 REM ===================================================
20 REM LADDER - 1982 CLASSIC CP/M ASCII PLATFORM CLIMBER
30 REM FOR CP/M MBASIC ON RUNCPM / RV32IM RETRO CONSOLE
40 REM ===================================================
50 PRINT "=============================================="
60 PRINT "          *** LADDER (1982 CP/M) ***          "
70 PRINT "=============================================="
80 PRINT "CLIMB LADDERS (#) AND DODGE ROLLING BOULDERS (O)!"
90 PRINT "REACH THE GOLD ($) AT THE TOP LEVEL TO WIN!"
100 PRINT "CONTROLS: 4=LEFT, 6=RIGHT, 8=CLIMB UP, 2=CLIMB DOWN"
110 PRINT "==============================================": PRINT
120 PX = 2: PY = 4: BX = 18: BY = 1: BDIR = 1: SCORE = 0: LIVES = 3
200 REM --- GAME LOOP ---
210 PRINT "LIVES:"; LIVES; " | SCORE:"; SCORE; " | LEVEL 1"
220 FOR Y = 1 TO 4
230   FOR X = 1 TO 20
240     IF X = PX AND Y = PY THEN PRINT "@";: GOTO 280
250     IF X = BX AND Y = BY THEN PRINT "O";: GOTO 280
260     IF X = 19 AND Y = 1 THEN PRINT "$";: GOTO 280
270     IF X = 10 AND Y > 1 AND Y < 4 THEN PRINT "#";: GOTO 280
275     IF X = 5 AND Y = 3 THEN PRINT "#";: GOTO 280
276     IF X = 15 AND Y = 2 THEN PRINT "#";: GOTO 280
278     IF Y = 4 THEN PRINT "=";: GOTO 280
279     IF Y = 3 AND (X < 8 OR X > 12) THEN PRINT "-";: GOTO 280
280     IF Y = 2 AND (X < 13 OR X > 17) THEN PRINT "-";: GOTO 280
281     IF Y = 1 THEN PRINT "=";: GOTO 280
282     PRINT " ";
283   NEXT X
284   PRINT
285 NEXT Y
286 IF PX = 19 AND PY = 1 GOTO 800
290 REM --- BOULDER MOVEMENT ---
300 BX = BX + BDIR
310 IF BX <= 1 THEN BDIR = 1: BY = BY + 1
320 IF BX >= 20 THEN BDIR = -1: BY = BY + 1
330 IF BY > 4 THEN BY = 1: BX = 18: BDIR = -1
340 IF PX = BX AND PY = BY GOTO 700
350 REM --- INPUT ---
360 INPUT "MOVE (4=L, 6=R, 8=U, 2=D, 5=WAIT)"; M$
370 IF M$ = "4" AND PX > 1 THEN PX = PX - 1
380 IF M$ = "6" AND PX < 20 THEN PX = PX + 1
390 IF M$ = "8" AND (PX = 10 OR (PX = 5 AND PY = 3) OR (PX = 15 AND PY = 2)) THEN PY = PY - 1: SCORE = SCORE + 50
400 IF M$ = "2" AND PY < 4 THEN PY = PY + 1
410 IF PX = BX AND PY = BY GOTO 700
420 SCORE = SCORE + 10
430 GOTO 200
700 REM --- HIT BY BOULDER ---
710 PRINT: PRINT "*** CRUNCH! A BOULDER HIT YOU! ***"
720 LIVES = LIVES - 1
730 IF LIVES <= 0 GOTO 900
740 PX = 2: PY = 4: BX = 18: BY = 1: BDIR = 1: GOTO 200
800 REM --- WIN ---
810 PRINT "=============================================="
820 PRINT "*** VICTORY! YOU REACHED THE SACRED GOLD ($)! ***"
830 PRINT "FINAL SCORE: "; SCORE + 1000
840 PRINT "==============================================": END
900 REM --- GAME OVER ---
910 PRINT "================ GAME OVER ================"
920 PRINT "ALL LIVES EXHAUSTED! FINAL SCORE: "; SCORE
930 PRINT "===========================================": END
