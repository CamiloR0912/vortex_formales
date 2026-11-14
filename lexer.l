/* ==========================================================================
 * lexer.l - Analizador léxico del lenguaje Vortex (.vx)
 *
 * Tiene dos modos, según cómo se compile:
 *   - Con el parser (por defecto): cada regla DEVUELVE su token a Bison.
 *   - Solo léxico (gcc -DLEXER_ONLY): imprime cada token con su línea.
 *
 * En ambos modos reporta los errores léxicos sin detenerse:
 *   - carácter inválido            ej:  @   #   $   ñ
 *   - cadena sin cerrar            ej:  "hola
 *   - comentario de bloque abierto ej:  / * ... (fin de archivo)
 * ========================================================================== */

%option noyywrap
%option yylineno
%option 8bit

%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern FILE *yyin;

int num_tokens = 0;      /* tokens válidos reconocidos                     */
int num_errors = 0;      /* errores encontrados (el parser suma los suyos) */
int comment_line = 0;    /* línea donde abrió un comentario                */

/* Imprime un token: línea, categoría y lexema (modo solo léxico) */
void token(const char *category) {
    num_tokens++;
    printf("line %-4d %-12s %s\n", yylineno, category, yytext);
}

/* Reporta un error léxico con su línea; el análisis continúa */
void lex_error(int line, const char *msg) {
    num_errors++;
    printf("[Lexical error] line %d: %s\n", line, msg);
}

#ifdef LEXER_ONLY
  /* Solo léxico: se imprime la categoría y se ignora el código del token */
  #define TOKEN(category, code)  token(category)
  #define SAVE_LEXEME()
#else
  /* Con el parser: se devuelve el código que Bison definió en parser.tab.h */
  #include "parser.tab.h"
  #define TOKEN(category, code)  return (code)
  /* Copia el lexema para que el parser lo use en sus mensajes de error */
  #define SAVE_LEXEME()          (yylval.str = strdup(yytext))
  /* Antes de cada regla: le pasa a Bison la línea del token (para @n) */
  #define YY_USER_ACTION         yylloc.first_line = yylloc.last_line = yylineno;
#endif
%}

/* ---- Definiciones regulares ---- */
DIGITO      [0-9]
LETRA       [a-zA-Z_]
ID          {LETRA}({LETRA}|{DIGITO})*
ENTERO      {DIGITO}+
FLOTANTE    {DIGITO}+\.{DIGITO}+
CADENA      \"([^"\\\n]|\\.)*\"
CADENA_ABIERTA \"([^"\\\n]|\\.)*
OP          [+\-*/%=<>!]
DELIM       [(){}\[\],;:]
UTF8        [\xC0-\xF7][\x80-\xBF]+
ESPACIO     [ \t\r\n]+

/* Estado exclusivo para el interior de un comentario de bloque */
%x COMMENT

%%

 /* ---- Comentarios: se ignoran, pero yylineno sigue contando saltos ---- */
"//"[^\n]*                  { /* comentario de línea */ }
"/*"                        { comment_line = yylineno; BEGIN(COMMENT); }
<COMMENT>"*/"               { BEGIN(INITIAL); }
<COMMENT>[^*]+              { /* contenido del comentario */ }
<COMMENT>"*"                { /* un '*' que no cierra */ }
<COMMENT><<EOF>>            { lex_error(comment_line, "unterminated block comment");
                              BEGIN(INITIAL); return 0; }

 /* ---- Palabras reservadas: van ANTES de {ID} para ganar el empate ----
  * Cada una tiene su propio token para que el parser las distinga.     */
"int"                       { TOKEN("TYPE", T_INT); }
"float"                     { TOKEN("TYPE", T_FLOAT); }
"bool"                      { TOKEN("TYPE", T_BOOL); }
"string"                    { TOKEN("TYPE", T_STRING); }
"void"                      { TOKEN("TYPE", T_VOID); }
"vector"                    { TOKEN("TYPE", T_VECTOR); }
"matrix"                    { TOKEN("TYPE", T_MATRIX); }

"func"                      { TOKEN("KEYWORD", FUNC); }
"if"                        { TOKEN("KEYWORD", IF); }
"else"                      { TOKEN("KEYWORD", ELSE); }
"while"                     { TOKEN("KEYWORD", WHILE); }
"for"                       { TOKEN("KEYWORD", FOR); }
"switch"                    { TOKEN("KEYWORD", SWITCH); }
"case"                      { TOKEN("KEYWORD", CASE); }
"default"                   { TOKEN("KEYWORD", DEFAULT); }
"break"                     { TOKEN("KEYWORD", BREAK); }
"continue"                  { TOKEN("KEYWORD", CONTINUE); }
"return"                    { TOKEN("KEYWORD", RETURN); }
"try"                       { TOKEN("KEYWORD", TRY); }
"catch"                     { TOKEN("KEYWORD", CATCH); }
"throw"                     { TOKEN("KEYWORD", THROW); }
"assert"                    { TOKEN("KEYWORD", ASSERT); }
"print"                     { TOKEN("KEYWORD", PRINT); }

"sum"                       { TOKEN("BUILTIN", SUM); }
"prod"                      { TOKEN("BUILTIN", PROD); }
"max"                       { TOKEN("BUILTIN", MAX); }
"min"                       { TOKEN("BUILTIN", MIN); }
"len"                       { TOKEN("BUILTIN", LEN); }

"true"|"false"              { TOKEN("BOOL_LIT", BOOL_LIT); }

 /* ---- Literales e identificadores ---- */
{FLOTANTE}                  { TOKEN("FLOAT_LIT", FLOAT_LIT); }
{ENTERO}                    { TOKEN("INT_LIT", INT_LIT); }
{CADENA}                    { TOKEN("STRING_LIT", STRING_LIT); }
{CADENA_ABIERTA}            { lex_error(yylineno, "unterminated string"); }
{ID}                        { SAVE_LEXEME(); TOKEN("IDENTIFIER", IDENTIFIER); }

 /* ---- Operadores y delimitadores ----
  * Los de dos caracteres tienen token propio; los de uno se devuelven
  * como el carácter mismo ('+', ';', ...), igual que los usa parser.y. */
"=="                        { TOKEN("OPERATOR", EQ); }
"!="                        { TOKEN("OPERATOR", NE); }
"<="                        { TOKEN("OPERATOR", LE); }
">="                        { TOKEN("OPERATOR", GE); }
"&&"                        { TOKEN("OPERATOR", AND); }
"||"                        { TOKEN("OPERATOR", OR); }
{OP}                        { TOKEN("OPERATOR", yytext[0]); }
{DELIM}                     { TOKEN("DELIMITER", yytext[0]); }

{ESPACIO}                   { /* ignorar espacios y saltos de línea */ }

 /* ---- Cualquier otra cosa es un error léxico ---- */
{UTF8}                      { char msg[64];   /* ñ, á, π... cuentan como UN carácter */
                              snprintf(msg, sizeof msg, "invalid character '%s'", yytext);
                              lex_error(yylineno, msg); }
.                           { char msg[64];
                              snprintf(msg, sizeof msg, "invalid character '%s'", yytext);
                              lex_error(yylineno, msg); }

%%

#ifdef LEXER_ONLY
/* main del modo solo léxico; con el parser, el main está en parser.y */
int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s file.vx\n", argv[0]);
        return 1;
    }
    yyin = fopen(argv[1], "r");
    if (yyin == NULL) {
        fprintf(stderr, "Cannot open file: %s\n", argv[1]);
        return 1;
    }

    yylex();
    fclose(yyin);

    printf("%d token(s), %d lexical error(s) found.\n", num_tokens, num_errors);
    return num_errors > 0;   /* código de salida 1 si hubo errores */
}
#endif
