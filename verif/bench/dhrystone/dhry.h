/*
 ****************************************************************************
 *
 *                   "DHRYSTONE" Benchmark Program
 *                   -----------------------------
 *
 *  Version:    C, Version 2.1
 *
 *  File:       dhry.h (part 1 of 3)
 *
 *  Date:       May 25, 1988
 *
 *  Author:     Reinhold P. Weicker
 *                      Siemens AG, E STE 35
 *                      Postfach 3240
 *                      8520 Erlangen
 *                      Germany (West)
 *
 *              Original Version (in Ada) published in
 *              "Communications of the ACM" vol. 27., no. 10 (Oct. 1984),
 *              pp. 1013 - 1030, together with the statistics
 *              on which the distribution of statements etc. is based.
 *
 *              Public-domain Reinhold P. Weicker Dhrystone 2.1 C sources,
 *              with minimal freestanding guards (#ifdef DHRY_EMBEDDED)
 *              matching SiFive benchmark-dhrystone / nand2mario z486.
 *
 ****************************************************************************
 */

#ifndef DHRY_EMBEDDED
#ifndef TIME
#undef TIMES
#define TIMES
#endif

#ifdef MSC_CLOCK
#undef HZ
#undef TIMES
#include <time.h>
#define HZ CLK_TCK
#endif

#ifdef TIMES
#include <sys/types.h>
#include <sys/times.h>
#endif
#endif

#define Mic_secs_Per_Second     1000000

#ifdef  NOSTRUCTASSIGN
#define structassign(d, s)      memcpy(&(d), &(s), sizeof(d))
#else
#define structassign(d, s)      d = s
#endif

#ifdef  NOENUM
#define Ident_1 0
#define Ident_2 1
#define Ident_3 2
#define Ident_4 3
#define Ident_5 4
  typedef int   Enumeration;
#else
  typedef       enum    {Ident_1, Ident_2, Ident_3, Ident_4, Ident_5}
                Enumeration;
#endif

#ifndef DHRY_EMBEDDED
#include <stdio.h>
#else
extern char *strcpy (char *dst, const char *src);
extern int strcmp (const char *lhs, const char *rhs);
#endif

#define Null 0
#define true  1
#define false 0

typedef int     One_Thirty;
typedef int     One_Fifty;
typedef char    Capital_Letter;
typedef int     Boolean;
typedef char    Str_30 [31];
typedef int     Arr_1_Dim [50];
typedef int     Arr_2_Dim [50] [50];

typedef struct record
    {
    struct record *Ptr_Comp;
    Enumeration    Discr;
    union {
          struct {
                  Enumeration Enum_Comp;
                  int         Int_Comp;
                  char        Str_Comp [31];
                  } var_1;
          struct {
                  Enumeration E_Comp_2;
                  char        Str_2_Comp [31];
                  } var_2;
          struct {
                  char        Ch_1_Comp;
                  char        Ch_2_Comp;
                  } var_3;
          } variant;
      } Rec_Type, *Rec_Pointer;
