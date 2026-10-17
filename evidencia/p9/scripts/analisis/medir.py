"""
medir.py — Calcula el RTO y el RPO REALES a partir de lo registrado.

No estima nada: todo sale de archivos que la prueba escribió mientras
ocurría.

  --escritas      marcas insertadas antes del desastre   (id|creado|contenido)
  --recuperadas   marcas presentes después de restaurar  (id|creado|contenido)
  --sonda         una línea por petición a la URL pública (UTC código tiempo)
  --desastre      instante en que empezó la destrucción (UTC)
  --respaldo      inicio del respaldo restaurado (UTC), del ConfigMap del Job
  --huella-antes / --huella-despues   tabla filas md5, por tabla

Definiciones (las mismas de P9/docs/01-objetivos-rto-rpo.md):

  RTO medido  = primera respuesta 200 tras el desastre − primera respuesta
                fallida tras el desastre. Es el tiempo que un USUARIO no pudo
                usar el sistema, medido desde fuera.
  RPO medido  = última marca escrita antes del desastre − última marca
                recuperada. Es la ventana de escrituras perdidas: lo que
                estaba confirmado en la base y no volvió.
"""
import argparse
import datetime as dt
import sys


def t(s):
    s = s.strip().replace("Z", "+00:00")
    return dt.datetime.fromisoformat(s)


def mmss(seg):
    seg = int(round(seg))
    return f"{seg // 60} min {seg % 60:02d} s"


def leer_marcas(ruta):
    marcas = {}
    for linea in open(ruta, encoding="utf-8"):
        partes = linea.strip().split("|")
        if len(partes) == 3 and partes[0].isdigit():
            marcas[int(partes[0])] = (t(partes[1]), partes[2])
    return marcas


def leer_huella(ruta):
    h = {}
    for linea in open(ruta, encoding="utf-8"):
        partes = linea.split()
        if len(partes) == 3:
            h[partes[0]] = (int(partes[1]), partes[2])
    return h


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--escritas", required=True)
    a.add_argument("--recuperadas", required=True)
    a.add_argument("--sonda")
    a.add_argument("--desastre", required=True)
    a.add_argument("--respaldo")
    a.add_argument("--huella-antes")
    a.add_argument("--huella-despues")
    a.add_argument("--rto-declarado-min", type=float)
    a.add_argument("--rpo-declarado-min", type=float)
    x = a.parse_args()

    t_desastre = t(x.desastre)
    print(f"Desastre (inicio de la destrucción)  {t_desastre:%Y-%m-%dT%H:%M:%SZ}")

    # --- RTO, desde fuera ---------------------------------------------------
    rto = None
    if x.sonda:
        filas = []
        for linea in open(x.sonda, encoding="utf-8"):
            p = linea.split()
            if len(p) >= 2:
                filas.append((t(p[0]), p[1]))
        tras = [f for f in filas if f[0] >= t_desastre]
        caida = next((f[0] for f in tras if f[1] != "200"), None)
        vuelta = next((f[0] for f in tras if caida and f[0] > caida and f[1] == "200"), None)
        print()
        print("RTO — disponibilidad medida desde la URL pública")
        print(f"  primera petición fallida      {caida:%H:%M:%SZ}" if caida else "  ninguna petición falló")
        print(f"  primera respuesta 200 después {vuelta:%H:%M:%SZ}" if vuelta else "  el servicio no volvió durante la sonda")
        if caida and vuelta:
            rto = (vuelta - caida).total_seconds()
            print(f"  RTO MEDIDO                    {mmss(rto)}")

    # --- RPO, desde dentro de la base ----------------------------------------
    escritas = leer_marcas(x.escritas)
    recuperadas = leer_marcas(x.recuperadas)
    antes = {i: v for i, v in escritas.items() if v[0] < t_desastre}
    vueltas = {i: v for i, v in antes.items() if i in recuperadas}
    perdidas = {i: v for i, v in antes.items() if i not in recuperadas}
    distintas = [i for i in vueltas if recuperadas[i][1] != antes[i][1]]

    print()
    print("RPO — marcas escritas en ops_db.p9_marcas antes del desastre")
    print(f"  escritas antes del desastre   {len(antes)}")
    print(f"  recuperadas, contenido IGUAL  {len(vueltas) - len(distintas)}")
    print(f"  recuperadas, contenido DISTINTO {len(distintas)}")
    print(f"  perdidas                      {len(perdidas)}")
    rpo = None
    if antes:
        ultima_escrita = max(v[0] for v in antes.values())
        if vueltas:
            ultima_vuelta = max(v[0] for v in vueltas.values())
            rpo = (ultima_escrita - ultima_vuelta).total_seconds()
            print(f"  última marca recuperada       {ultima_vuelta:%H:%M:%S.%f}"[:-3] + "Z")
        print(f"  última marca escrita          {ultima_escrita:%H:%M:%S.%f}"[:-3] + "Z")
        if perdidas:
            ps = sorted(v[0] for v in perdidas.values())
            print(f"  ventana perdida               {ps[0]:%H:%M:%S}Z → {ps[-1]:%H:%M:%S}Z")
        if rpo is not None:
            print(f"  RPO MEDIDO                    {mmss(rpo)}")
    if x.respaldo:
        r = t(x.respaldo)
        print(f"  respaldo restaurado: inició   {r:%H:%M:%SZ}  ({mmss((t_desastre - r).total_seconds())} antes del desastre)")
        tardias = [i for i, v in vueltas.items() if v[0] > r]
        if tardias:
            print(f"  {len(tardias)} marcas recuperadas son posteriores al inicio del respaldo:")
            print("  el snapshot del disco se tomó segundos DESPUÉS de empezar el respaldo")

    # --- Huella: contenido real, tabla por tabla ---------------------------------
    if x.huella_antes and x.huella_despues:
        ha, hd = leer_huella(x.huella_antes), leer_huella(x.huella_despues)
        print()
        print("Huella de las bases (filas y md5 de TODO el contenido, por tabla)")
        print(f"  {'tabla':44} {'antes':>7} {'después':>8}  resultado")
        for tabla in sorted(set(ha) | set(hd)):
            fa, ma = ha.get(tabla, (0, "-"))
            fd, md = hd.get(tabla, (0, "-"))
            if ma == md:
                res = "idéntica"
            elif fd < fa:
                res = f"faltan {fa - fd} filas (escritas tras el respaldo)"
            else:
                res = "distinta"
            print(f"  {tabla:44} {fa:>7} {fd:>8}  {res}")

    # --- Contra lo declarado ------------------------------------------------------
    print()
    print("Declarado frente a medido")
    if x.rto_declarado_min and rto is not None:
        ok = "CUMPLE" if rto <= x.rto_declarado_min * 60 else "NO CUMPLE"
        print(f"  RTO  declarado {x.rto_declarado_min:g} min · medido {mmss(rto)} · {ok}")
    if x.rpo_declarado_min and rpo is not None:
        ok = "CUMPLE" if rpo <= x.rpo_declarado_min * 60 else "NO CUMPLE"
        print(f"  RPO  declarado {x.rpo_declarado_min:g} min · medido {mmss(rpo)} · {ok}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
