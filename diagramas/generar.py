#!/usr/bin/env python3
"""Genera los diagramas del informe a partir de las fuentes del proyecto.

    python3 diagramas/generar.py      (requiere graphviz: el comando dot)

Produce, dentro de diagramas/:
  lexico_*.png            un autómata por cada automatas/*.jff (JFLAP)
  lalr_if_else.png        estados del autómata LALR(1) que leen if / else
  lalr_try_catch.png      estados del autómata LALR(1) que leen try / catch
  arquitectura.png        cómo interactúan lexer.l, parser.y y sus derivados

Los fragmentos LALR salen de parser.dot, que crea Bison (ver el script run).
El autómata completo tiene 279 estados y graphviz no logra dibujarlo en un
tiempo razonable; su descripción completa en texto está en parser.output.
"""
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

AQUI = Path(__file__).resolve().parent
RAIZ = AQUI.parent

# Símbolos que en los .jff representan una clase de caracteres
CLASES = {"L": "letra, _", "D": "dígito", "#": "otro"}


def dot(fuente: str, salida: Path) -> None:
    """Escribe el .dot junto a la imagen y lo convierte con graphviz."""
    archivo_dot = salida.with_suffix(".dot")
    archivo_dot.write_text(fuente, encoding="utf-8")
    formato = salida.suffix[1:]
    subprocess.run(["dot", f"-T{formato}", "-Gdpi=150", str(archivo_dot), "-o", str(salida)],
                   check=True)
    print("generado", salida.relative_to(RAIZ))


def comillas(texto: str) -> str:
    """Escapa un texto para usarlo como etiqueta en DOT."""
    return texto.replace("\\", "\\\\").replace('"', '\\"')


# --------------------------------------------------------------------------
# 1. Autómatas del analizador léxico (archivos de JFLAP)
# --------------------------------------------------------------------------
def automata_lexico(jff: Path) -> None:
    automata = ET.parse(jff).getroot().find("automaton")
    lineas = ["digraph {", "  rankdir=LR;",
              '  node [fontname="Helvetica", fontsize=11];',
              '  edge [fontname="Helvetica", fontsize=11];',
              "  inicio [shape=point, width=0.1];"]

    # La descripción de cada estado va en una leyenda debajo del autómata
    leyenda = []
    for estado in automata.findall("state"):
        forma = "doublecircle" if estado.find("final") is not None else "circle"
        nota = estado.findtext("label") or ""
        lineas.append(f'  {estado.get("id")} [shape={forma}, label="{estado.get("name")}"];')
        leyenda.append(f'{estado.get("name")}:  {comillas(nota)}\\l')
        if estado.find("initial") is not None:
            lineas.append(f'  inicio -> {estado.get("id")};')
    lineas.append(f'  label="{"".join(leyenda)}"; labelloc=b; labeljust=l; '
                  'fontname="Helvetica"; fontsize=10;')

    # Las transiciones entre el mismo par de estados se dibujan como una sola
    arcos = {}
    for t in automata.findall("transition"):
        simbolo = t.findtext("read") or "ε"
        simbolo = CLASES.get(simbolo, simbolo)
        arcos.setdefault((t.findtext("from"), t.findtext("to")), []).append(simbolo)
    for (origen, destino), simbolos in arcos.items():
        lineas.append(f'  {origen} -> {destino} [label="{comillas("  ".join(simbolos))}"];')

    lineas.append("}")
    dot("\n".join(lineas), AQUI / f"lexico_{jff.stem}.png")


# --------------------------------------------------------------------------
# 2. Fragmentos del autómata LALR(1) del analizador sintáctico
# --------------------------------------------------------------------------
def fragmento_lalr(reglas: set, salida: Path) -> None:
    """Conserva los estados que ya avanzaron dentro de alguna de las reglas.

    Un estado entra al fragmento si tiene un ítem de esas reglas con el punto
    (•) después de al menos un símbolo; así quedan fuera los estados donde la
    regla apenas podría empezar.
    """
    texto = (RAIZ / "parser.dot").read_text(encoding="utf-8")
    nodos = dict(re.findall(r'^\s*(\d+) \[label="(.*)"\]$', texto, re.M))

    def avanzo(etiqueta: str) -> bool:
        for item in etiqueta.split("\\l"):
            m = re.match(r"\s*(\d+) (?:\S+:|\s*\|) (.*)", item)
            if m and int(m.group(1)) in reglas and not m.group(2).startswith("•"):
                return True
        return False

    elegidos = {n for n, etiqueta in nodos.items() if avanzo(etiqueta)}
    lineas = ["digraph {",
              "  node [fontname=courier, fontsize=10, shape=box, colorscheme=paired6];",
              "  edge [fontname=courier, fontsize=10];"]
    for n in sorted(elegidos, key=int):
        lineas.append(f'  {n} [label="{nodos[n]}"];')
    # Transiciones entre los estados elegidos y sus reducciones (rombos)
    for linea in texto.splitlines():
        m = re.match(r'\s*(\d+) -> "?(\d+)(R\d+d?)?"?', linea)
        if not m or m.group(1) not in elegidos:
            continue
        if m.group(3) or m.group(2) in elegidos:
            lineas.append(linea)
    for linea in texto.splitlines():
        m = re.match(r'\s*"(\d+)R\d+d?" \[', linea)
        if m and m.group(1) in elegidos:
            lineas.append(linea)
    lineas.append("}")
    dot("\n".join(lineas), salida)


# --------------------------------------------------------------------------
# 3. Arquitectura: construcción y ejecución del analizador
# --------------------------------------------------------------------------
ARQUITECTURA = r"""
digraph {
  rankdir=LR; compound=true; nodesep=0.35; ranksep=0.6;
  node [fontname="Helvetica", fontsize=11, shape=box, style="rounded,filled", fillcolor="#f4f4f4"];
  edge [fontname="Helvetica", fontsize=10];

  subgraph cluster_construccion {
    label="Construcción (script run)"; fontname="Helvetica"; style=dashed;
    lexer_l   [label="lexer.l\nreglas léxicas", fillcolor="#dbe9f6"];
    parser_y  [label="parser.y\ngramática y reglas de error", fillcolor="#dbe9f6"];
    flex      [label="flex", shape=ellipse, style=filled];
    bison     [label="bison -d -v", shape=ellipse, style=filled];
    lex_c     [label="lex.yy.c\nAFD en C: yylex()"];
    tab_c     [label="parser.tab.c\ntablas LALR(1): yyparse()"];
    tab_h     [label="parser.tab.h\ncódigos de token,\nYYSTYPE, YYLTYPE"];
    gcc       [label="gcc", shape=ellipse, style=filled];
    vortex    [label="vortex\nejecutable", fillcolor="#dff0d8"];

    lexer_l -> flex -> lex_c -> gcc;
    parser_y -> bison;
    bison -> tab_c -> gcc;
    bison -> tab_h;
    tab_h -> lex_c [label="#include", style=dashed];
    gcc -> vortex;
  }

  subgraph cluster_ejecucion {
    label="Ejecución (./vortex programa.vx)"; fontname="Helvetica"; style=dashed;
    fuente  [label="programa.vx", fillcolor="#dbe9f6"];
    yylex   [label="yylex()\nanalizador léxico"];
    yyparse [label="yyparse()\nanalizador sintáctico"];
    salida  [label="Syntactically valid program.\no lista de errores con su línea", fillcolor="#dff0d8"];

    fuente -> yylex [label="caracteres\n(yyin)"];
    yylex -> yyparse [label="token\nyylval: lexema\nyylloc: línea"];
    yyparse -> yylex [label="pide el siguiente token", style=dashed];
    yylex -> salida [label="[Lexical error]"];
    yyparse -> salida [label="[Syntax error]\n[Invalid construct]"];
  }
}
"""


def main() -> None:
    for jff in sorted((RAIZ / "automatas").glob("*.jff")):
        automata_lexico(jff)

    # Números de regla tomados de parser.output
    fragmento_lalr({36, 37, 38}, AQUI / "lalr_if_else.png")     # if_stmt
    fragmento_lalr({79, 80}, AQUI / "lalr_try_catch.png")       # try_stmt

    dot(ARQUITECTURA, AQUI / "arquitectura.png")


if __name__ == "__main__":
    main()
