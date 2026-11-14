/* ==========================================================================
 * parser.y - Analizador sintáctico del lenguaje Vortex (.vx)
 *
 * Recibe los tokens de lexer.l y valida la estructura del programa.
 * No ejecuta nada: solo dice si el programa es sintácticamente válido y
 * reporta cada error con su línea, en tres categorías:
 *   [Lexical error]      carácter o lexema inválido (lo reporta lexer.l)
 *   [Invalid construct]  constructo reconocido pero mal formado; lo detecta
 *                        una regla de producción adicional (regla de error)
 *   [Syntax error]       cualquier otro error de sintaxis (mensaje de Bison)
 * ========================================================================== */

%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int yylex(void);
void yyerror(const char *s);

extern FILE *yyin;
extern int yylineno;
extern int num_errors;          /* definido en lexer.l: total de errores */

/* ---- Error de sintaxis pendiente ----------------------------------------
 * Bison llama a yyerror() ANTES de saber qué regla de error va a recuperar
 * el análisis. Por eso yyerror() no imprime: guarda el mensaje. Luego la
 * regla que recupera decide cómo se reporta:
 *   - una regla específica  -> [Invalid construct] (invalid_from_error)
 *   - la regla genérica     -> [Syntax error]      (flush_pending)        */
static char pending_msg[256];
static int  pending_line = 0;
static int  has_pending  = 0;

/* Imprime el error pendiente como error de sintaxis genérico */
static void flush_pending(void) {
    if (!has_pending) return;
    printf("[Syntax error] line %d: %s\n", pending_line, pending_msg);
    num_errors++;
    has_pending = 0;
}

/* Constructo inválido detectado por una regla SIN el token error:
 * la línea se toma de la ubicación (@n) de un símbolo de la regla */
static void invalid_at(int line, const char *msg) {
    flush_pending();
    printf("[Invalid construct] line %d: %s\n", line, msg);
    num_errors++;
}

/* Constructo inválido detectado por una regla CON el token error:
 * usa la línea del error pendiente y agrega el detalle de Bison
 * ("unexpected X, expecting Y") entre paréntesis */
static void invalid_from_error(const char *msg) {
    const char *detail = pending_msg;
    if (!has_pending) return;                 /* ya se reportó este error */
    if (strncmp(detail, "syntax error, ", 14) == 0) detail += 14;
    printf("[Invalid construct] line %d: %s (%s)\n", pending_line, msg, detail);
    num_errors++;
    has_pending = 0;
}

/* Igual que invalid_at, pero con el nombre de un identificador en el mensaje */
static void invalid_name(int line, const char *fmt, const char *name) {
    char msg[256];
    snprintf(msg, sizeof msg, fmt, name);
    invalid_at(line, msg);
}
%}

/* Mensajes "unexpected X, expecting Y" y ubicación (línea) de cada símbolo */
%define parse.error verbose
%locations

/* Valores semánticos: el lexema de un identificador o una bandera entera */
%union {
    char *str;
    int   flag;
}

/* ---- Tokens ----
 * El texto entre comillas es el nombre que Bison usa en los mensajes. */

/* Tipos: un token distinto por tipo, así la gramática los diferencia */
%token T_INT "int" T_FLOAT "float" T_BOOL "bool" T_STRING "string"
%token T_VOID "void" T_VECTOR "vector" T_MATRIX "matrix"

/* Palabras reservadas */
%token FUNC "func" IF "if" ELSE "else" WHILE "while" FOR "for"
%token SWITCH "switch" CASE "case" DEFAULT "default"
%token BREAK "break" CONTINUE "continue" RETURN "return"
%token TRY "try" CATCH "catch" THROW "throw" ASSERT "assert" PRINT "print"

/* Funciones de reducción */
%token SUM "sum" PROD "prod" MAX "max" MIN "min" LEN "len"

/* Literales e identificadores */
%token INT_LIT "integer literal" FLOAT_LIT "float literal"
%token STRING_LIT "string literal" BOOL_LIT "boolean literal"
%token <str> IDENTIFIER "identifier"

/* Operadores de dos caracteres (los de uno se usan como literal: '+') */
%token EQ "==" NE "!=" LE "<=" GE ">=" AND "&&" OR "||"

/* Bandera: en expresiones, 1 si se puede asignar (variable o v[i]);
 * en listas de argumentos, 1 si ya apareció un argumento nombrado */
%type <flag> expr or_expr and_expr eq_expr rel_expr add_expr mul_expr
%type <flag> unary postfix primary arg_list arg

/* Libera el lexema de un identificador descartado al recuperar un error */
%destructor { free($$); } <str>

/* ---- Conflictos desplazar/reducir resueltos con precedencia ----
 * 1. Después de "if (c) { }" con un 'else' adelante, Bison puede reducir el
 *    if (y el else quedaría huérfano) o desplazar el else. ELSE tiene más
 *    precedencia que la regla sin else (%prec NO_ELSE): gana desplazar.
 * 2. Lo mismo con "try { }" seguido de 'catch'. */
%nonassoc NO_ELSE
%nonassoc ELSE
%nonassoc NO_CATCH
%nonassoc CATCH

%start program

%%

/* ===================== Programa y sentencias ===================== */

program:
    stmt_list
    ;

stmt_list:
    %empty
    | stmt_list stmt
    ;

stmt:
    var_decl
    | simple_stmt ';'
    | block
    | if_stmt
    | while_stmt
    | for_stmt
    | switch_stmt
    | func_def
    | try_stmt
    | jump_stmt
    | assert_stmt
    | print_stmt
    | invalid_stmt
    /* Recuperación genérica: descarta tokens hasta el siguiente ';' o hasta
     * el siguiente bloque completo, y el análisis continúa desde ahí */
    | error ';'     { flush_pending(); yyerrok; }
    | error block   { flush_pending(); yyerrok; }
    ;

/* Un bloque siempre va entre llaves. Como block es una sentencia y contiene
 * una lista de sentencias, los bloques se anidan y cada uno puede declarar
 * variables propias, incluso repitiendo un nombre externo (shadowing). */
block:
    '{' stmt_list '}'
    ;

/* ===================== Tipos y declaraciones ===================== */

basic_type:
    T_INT | T_FLOAT | T_BOOL | T_STRING
    ;

/* vector<T> y matrix<T> solo aceptan un tipo básico como elemento */
type:
    basic_type
    | T_VECTOR '<' basic_type '>'
    | T_MATRIX '<' basic_type '>'
    ;

/* Toda variable se declara con su tipo y un valor inicial */
var_decl:
    type IDENTIFIER '=' expr ';'    { free($2); }
    /* Reglas de error */
    | type IDENTIFIER ';'
        { invalid_name(@2.first_line, "variable '%s' must be initialized", $2); free($2); }
    | T_VECTOR IDENTIFIER '=' expr ';'
        { invalid_at(@1.first_line, "'vector' requires an element type, e.g. vector<int>"); free($2); }
    | T_MATRIX IDENTIFIER '=' expr ';'
        { invalid_at(@1.first_line, "'matrix' requires an element type, e.g. matrix<int>"); free($2); }
    ;

/* Asignación o expresión suelta (una llamada, por ejemplo).
 * Factor común: "x = 1" y "f(x)" empiezan igual, así que ambas se leen como
 * expr y la bandera dice si el lado izquierdo del '=' se puede asignar. */
simple_stmt:
    expr
    | expr '=' expr
        { if (!$1) invalid_at(@1.first_line, "invalid assignment target"); }
    ;

/* ===================== Control de flujo ===================== */

/* Condición entre paréntesis, compartida por if, while y switch */
condition:
    '(' expr ')'
    /* Reglas de error */
    | '(' expr '=' expr ')'
        { invalid_at(@3.first_line, "assignment '=' used as a condition; use '==' to compare"); }
    | '(' error ')'
        { invalid_from_error("invalid condition"); yyerrok; }
    ;

if_stmt:
    IF condition block %prec NO_ELSE
    | IF condition block ELSE block
    | IF condition block ELSE if_stmt        /* else if encadenado */
    /* Reglas de error */
    | IF error
        { invalid_from_error("condition must be enclosed in parentheses"); }
      block
        { yyerrok; }
    | IF condition error ';'
        { invalid_from_error("body must be enclosed in braces { }"); yyerrok; }
    | IF condition block ELSE error ';'
        { invalid_from_error("body must be enclosed in braces { }"); yyerrok; }
    ;

while_stmt:
    WHILE condition block
    /* Reglas de error */
    | WHILE error
        { invalid_from_error("condition must be enclosed in parentheses"); }
      block
        { yyerrok; }
    | WHILE condition error ';'
        { invalid_from_error("body must be enclosed in braces { }"); yyerrok; }
    ;

for_stmt:
    FOR '(' for_header ')' block
    /* Reglas de error */
    | FOR '(' error ')'
        { invalid_from_error("malformed 'for' header, expected for (init; condition; step)"); yyerrok; }
      block
    | FOR '(' for_header ')' error ';'
        { invalid_from_error("body must be enclosed in braces { }"); yyerrok; }
    ;

/* for (inicio; condición; paso) - las tres partes son opcionales */
for_header:
    for_init ';' expr_opt ';' for_step
    ;

for_init:
    %empty
    | type IDENTIFIER '=' expr      { free($2); }
    | simple_stmt
    ;

for_step:
    %empty
    | simple_stmt
    ;

expr_opt:
    %empty
    | expr
    ;

/* switch: cero o más case y, al final, un default opcional.
 * Cada rama lleva su bloque; no hay paso de una rama a la siguiente. */
switch_stmt:
    SWITCH condition '{' case_list default_opt '}'
    /* Regla de error: algo inválido dentro del switch (por ejemplo un case
     * después de default). Se salta hasta el final de esa rama y se siguen
     * leyendo ramas hasta la llave que cierra el switch. */
    | SWITCH condition '{' case_list default_opt switch_error '}'
        { yyerrok; }
    ;

switch_error:
    error block                             { flush_pending(); }
    | error ';'                             { flush_pending(); }
    | switch_error CASE expr ':' block
    | switch_error DEFAULT ':' block
    ;

case_list:
    %empty
    | case_list CASE expr ':' block
    ;

default_opt:
    %empty
    | DEFAULT ':' block
    ;

/* ===================== Funciones ===================== */

/* func <tipo de retorno> nombre(parámetros) { cuerpo }
 * El cuerpo es un block, y block contiene sentencias, que incluyen func_def
 * (funciones anidadas) y llamadas a la misma función (recursión).
 * Sobrecarga: se puede repetir el nombre con otros tipos de parámetros; la
 * gramática lo permite porque cada parámetro declara su tipo. */
func_def:
    FUNC return_type IDENTIFIER '(' params_opt ')' block    { free($3); }
    /* Regla de error */
    | FUNC return_type IDENTIFIER '(' params_opt ')' ';'
        { invalid_name(@3.first_line, "function '%s' has no body; use { }", $3); free($3); }
    ;

return_type:
    type
    | T_VOID
    ;

params_opt:
    %empty
    | param_list
    ;

param_list:
    param
    | param_list ',' param
    ;

/* Parámetro con tipo y, opcionalmente, valor por defecto */
param:
    type IDENTIFIER                 { free($2); }
    | type IDENTIFIER '=' expr      { free($2); }
    ;

/* ===================== Excepciones y validación ===================== */

try_stmt:
    TRY block CATCH '(' IDENTIFIER ')' block    { free($5); }
    /* Regla de error */
    | TRY block %prec NO_CATCH
        { invalid_at(@1.first_line, "'try' without 'catch'"); }
    ;

/* assert(condición) o assert(condición, mensaje) */
assert_stmt:
    ASSERT '(' expr ')' ';'
    | ASSERT '(' expr ',' expr ')' ';'
    /* Regla de error */
    | ASSERT '(' ')' ';'
        { invalid_at(@1.first_line, "'assert' requires a condition"); }
    ;

jump_stmt:
    RETURN ';'
    | RETURN expr ';'
    | BREAK ';'
    | CONTINUE ';'
    | THROW expr ';'
    ;

print_stmt:
    PRINT '(' expr_list_opt ')' ';'
    ;

/* Palabras reservadas que solo tienen sentido dentro de otra estructura.
 * Se aceptan como sentencia para reportar un mensaje específico. */
invalid_stmt:
    ELSE block
        { invalid_at(@1.first_line, "'else' without a matching 'if'"); }
    | ELSE if_stmt
        { invalid_at(@1.first_line, "'else' without a matching 'if'"); }
    | CASE expr ':' block
        { invalid_at(@1.first_line, "'case' outside of a 'switch'"); }
    | DEFAULT ':' block
        { invalid_at(@1.first_line, "'default' outside of a 'switch'"); }
    | CATCH '(' IDENTIFIER ')' block
        { invalid_at(@1.first_line, "'catch' without a preceding 'try'"); free($3); }
    ;

/* ===================== Expresiones =====================
 * La precedencia se resuelve estratificando la gramática: un no terminal por
 * nivel, del que menos liga (||) al que más liga (indexación). La recursión
 * por la izquierda hace que los operadores binarios asocien a la izquierda.
 *
 *   ||  <  &&  <  == !=  <  < > <= >=  <  + -  <  * / %  <  - ! (unarios)
 */

expr:
    or_expr
    ;

or_expr:
    and_expr
    | or_expr OR and_expr           { $$ = 0; }
    ;

and_expr:
    eq_expr
    | and_expr AND eq_expr          { $$ = 0; }
    ;

eq_expr:
    rel_expr
    | eq_expr EQ rel_expr           { $$ = 0; }
    | eq_expr NE rel_expr           { $$ = 0; }
    ;

rel_expr:
    add_expr
    | rel_expr '<' add_expr         { $$ = 0; }
    | rel_expr '>' add_expr         { $$ = 0; }
    | rel_expr LE add_expr          { $$ = 0; }
    | rel_expr GE add_expr          { $$ = 0; }
    ;

add_expr:
    mul_expr
    | add_expr '+' mul_expr         { $$ = 0; }
    | add_expr '-' mul_expr         { $$ = 0; }
    ;

mul_expr:
    unary
    | mul_expr '*' unary            { $$ = 0; }
    | mul_expr '/' unary            { $$ = 0; }
    | mul_expr '%' unary            { $$ = 0; }
    ;

unary:
    postfix
    | '-' unary                     { $$ = 0; }
    | '!' unary                     { $$ = 0; }
    ;

/* Indexación: v[i], m[i][j], f(x)[0] */
postfix:
    primary
    | postfix '[' expr ']'          { $$ = $1; }
    ;

primary:
    INT_LIT                         { $$ = 0; }
    | FLOAT_LIT                     { $$ = 0; }
    | STRING_LIT                    { $$ = 0; }
    | BOOL_LIT                      { $$ = 0; }
    | IDENTIFIER                    { $$ = 1; free($1); }   /* asignable */
    | IDENTIFIER '(' args_opt ')'   { $$ = 0; free($1); }   /* llamada */
    | reduction '(' expr ')'        { $$ = 0; }
    | '(' expr ')'                  { $$ = 0; }
    | '[' ']'                       { $$ = 0; }   /* vector vacío */
    | '[' expr_list ']'             { $$ = 0; }   /* literal de vector o matriz */
    ;

/* Operadores de reducción sobre vectores y matrices */
reduction:
    SUM | PROD | MAX | MIN | LEN
    ;

expr_list_opt:
    %empty
    | expr_list
    ;

expr_list:
    expr
    | expr_list ',' expr
    ;

/* Argumentos de una llamada: primero los posicionales, luego los nombrados */
args_opt:
    %empty
    | arg_list
    ;

arg_list:
    arg
    | arg_list ',' arg
        { if ($1 && !$3)
              invalid_at(@3.first_line, "positional argument after a named argument");
          $$ = $1 || $3; }
    ;

arg:
    expr                            { $$ = 0; }   /* posicional */
    | IDENTIFIER '=' expr           { $$ = 1; free($1); }   /* nombrado */
    ;

%%

/* Bison la llama al detectar un error de sintaxis. Solo guarda el mensaje y
 * la línea; lo imprime la regla que recupere el análisis (ver arriba). */
void yyerror(const char *s) {
    flush_pending();
    snprintf(pending_msg, sizeof pending_msg, "%s", s);
    pending_line = yylloc.first_line;
    has_pending = 1;
}

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

    yyparse();
    flush_pending();    /* error del que no se pudo recuperar (fin de archivo) */
    fclose(yyin);

    if (num_errors == 0) {
        printf("Syntactically valid program.\n");
        return 0;
    }
    printf("%d error(s) found.\n", num_errors);
    return 1;
}
