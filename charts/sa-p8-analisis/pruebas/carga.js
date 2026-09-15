/**
 * carga.js — La tercera puerta: ¿aguanta la versión candidata?
 *
 * ═══════════════════════════════════════════════════════════════════════════
 *  EN QUÉ SE DIFERENCIA DE LA PRUEBA DE CARGA DE LA PRÁCTICA 5
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * `P5/loadtest/k6-gateway.js` mide OTRA cosa y por eso está construida al
 * revés de esta. Aquella sube la carga en escalones durante nueve minutos para
 * provocar el autoescalado y poder señalar en qué escalón reaccionó el HPA: su
 * producto es una gráfica que se interpreta.
 *
 * Esta es una PUERTA. Su producto es un sí o un no, y lo tiene que producir
 * dentro de la pausa del canary. Eso cambia tres decisiones:
 *
 *   · Carga constante, no escalonada. Un escalón cambiaría la latencia por
 *     razones que no tienen que ver con la versión bajo prueba, y el umbral
 *     mediría el escalón en lugar del código.
 *
 *   · 90 segundos, no nueve minutos. La pausa más corta del canary es de dos
 *     minutos; una prueba más larga que la pausa dejaría avanzar el rollout
 *     con la medición a medias.
 *
 *   · Sin HPA en el ambiente donde corre (ver `values-stage.yaml`). Si el
 *     autoescalador añadiera réplicas a mitad de la medición, el resultado
 *     diría cuándo escaló y no si la versión nueva es buena.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 *  CONTRA QUIÉN CORRE
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Contra el Service canary, por DNS interno del clúster, sin pasar por el
 * Ingress. Es deliberado: por el Ingress llegaría la mezcla de las dos
 * versiones según el peso del canary, y con el canary al 10 % nueve de cada
 * diez peticiones medirían la versión estable. La media quedaría dentro del
 * umbral incluso con la versión nueva completamente rota.
 *
 * El costo de esta decisión, y se asume: no se mide la latencia que añade el
 * controlador de Ingress. No importa, porque es la misma para las dos
 * versiones y lo que se compara es una contra la otra.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 *  LOS UMBRALES, Y POR QUÉ ESTOS
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Los tres se pueden sobrescribir por variable de entorno desde la plantilla
 * de análisis, para poder endurecerlos en producción sin tocar este archivo.
 * Los valores por defecto salen de medir la versión estable —ver
 * `P8/docs/03-pruebas-y-umbrales.md`, que incluye la corrida de calibración—.
 *
 *   · `UMBRAL_ERRORES` (1 %). No es cero, y la razón importa: durante el
 *     canary conviven dos ReplicaSets y el controlador de Ingress recarga su
 *     configuración cada vez que cambia el peso. Esa recarga cierra conexiones
 *     en vuelo, y con `noConnectionReuse: false` eso produce algún error
 *     aislado que no tiene nada que ver con el código. Poner el umbral en cero
 *     haría que el canary abortara por su propio funcionamiento —un falso
 *     positivo que enseña a la gente a ignorar la alarma—.
 *
 *     Un 1 % sobre ~2700 peticiones son 27 fallos: muy por encima de las dos o
 *     tres recargas esperables, y muy por debajo de lo que produce un defecto
 *     real, que rompe una proporción del tráfico, no un puñado de peticiones.
 *
 *   · `UMBRAL_P95` (800 ms). La versión estable mide un p95 de ~180 ms en este
 *     clúster. El umbral está a más del cuádruple a propósito: p95 es sensible
 *     a que un pod nuevo esté calentando su JIT y sus pools de conexiones
 *     durante los primeros segundos, y un umbral pegado a la medición
 *     abortaría rollouts sanos. Lo que sí atrapa es el orden de magnitud: una
 *     consulta sin índice, un `await` en serie donde había paralelismo o un
 *     upstream que empezó a reintentar llevan el p95 a segundos, no a 900 ms.
 *
 *   · `UMBRAL_P99` (2000 ms). Va aparte porque captura algo que el p95 esconde:
 *     una fuga que degrada solo a una de cada cien peticiones. Sin él, un
 *     defecto que afecta al 1 % del tráfico pasaría las tres puertas.
 *
 * Los tres son umbrales `abortOnFail`, así que k6 termina en cuanto uno se
 * rompe en lugar de gastar los 90 segundos completos. El canary aborta antes
 * y el porcentaje de usuarios afectados es menor.
 */

import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const SERVICIO = __ENV.SERVICIO_CANARY;
const NAMESPACE = __ENV.NAMESPACE;
const PUERTO = __ENV.PUERTO || '8080';
const BASE = `http://${SERVICIO}.${NAMESPACE}.svc.cluster.local:${PUERTO}`;

const UMBRAL_ERRORES = __ENV.UMBRAL_ERRORES || '0.01';
const UMBRAL_P95 = __ENV.UMBRAL_P95 || '800';
const UMBRAL_P99 = __ENV.UMBRAL_P99 || '2000';
const VUS = parseInt(__ENV.VUS || '15', 10);
const DURACION = __ENV.DURACION || '90s';

// Métricas propias. Separar la latencia por tipo de petición evita que el
// promedio mezcle una consulta GraphQL con una sonda de salud y esconda cuál
// de las dos se degradó —que es justo lo que hay que saber para el informe de
// incidente—.
const latenciaSalud = new Trend('latencia_salud', true);
const latenciaCatalogo = new Trend('latencia_catalogo', true);
const tasaError = new Rate('tasa_de_error');

export const options = {
  scenarios: {
    constante: {
      executor: 'constant-vus',
      vus: VUS,
      duration: DURACION,
    },
  },

  thresholds: {
    tasa_de_error: [{ threshold: `rate<${UMBRAL_ERRORES}`, abortOnFail: true }],
    http_req_duration: [
      { threshold: `p(95)<${UMBRAL_P95}`, abortOnFail: true },
      { threshold: `p(99)<${UMBRAL_P99}`, abortOnFail: true },
    ],
  },

  // Sin esto, cada iteración negociaría TCP de nuevo y se mediría el costo de
  // abrir conexiones en vez del de atender peticiones.
  noConnectionReuse: false,

  // El resumen va al registro del Job, que es donde el análisis lo deja para
  // que se pueda leer después con `kubectl logs`.
  summaryTrendStats: ['avg', 'min', 'med', 'p(95)', 'p(99)', 'max'],
};

const params = {
  headers: { 'Content-Type': 'application/json' },
  timeout: '20s',
};

const CONSULTA_CATALOGO = JSON.stringify({
  query: '{ products(limit: 10) { items { id sku name price currency active } total } }',
});

export default function () {
  // --- Salud agregada: el peor caso a propósito ---------------------------
  //
  // Una petición aquí provoca cuatro salientes en paralelo a los cuatro
  // microservicios. Es la ruta más cara del gateway y la que primero acusa una
  // regresión en su cliente HTTP o en su manejo de concurrencia.
  const salud = http.get(`${BASE}/health`, params);
  latenciaSalud.add(salud.timings.duration);
  const saludOk = check(salud, {
    'salud responde 200': (r) => r.status === 200,
    'salud dice ok': (r) => r.status === 200 && r.json('status') === 'ok',
  });
  tasaError.add(!saludOk);

  // --- Catálogo: trabajo real, con base de datos detrás -------------------
  //
  // Es una lectura idempotente: se puede repetir miles de veces sin ensuciar
  // la base ni llenar la cola del broker. Una prueba de carga que creara
  // pedidos mediría lo mismo y dejaría decenas de miles de filas basura que el
  // consumidor tendría que drenar durante horas.
  const catalogo = http.post(`${BASE}/api/catalog`, CONSULTA_CATALOGO, params);
  latenciaCatalogo.add(catalogo.timings.duration);
  const catalogoOk = check(catalogo, {
    'catálogo responde 200': (r) => r.status === 200,
    // GraphQL devuelve 200 aunque la consulta falle, con los errores dentro
    // del cuerpo. Sin esta segunda comprobación, un catálogo roto pasaría la
    // puerta con un 0 % de error.
    'catálogo devuelve productos': (r) => r.status === 200 && r.body.includes('"products"'),
    'catálogo sin errores GraphQL': (r) => r.status === 200 && !r.body.includes('"errors"'),
  });
  tasaError.add(!catalogoOk);
}

/**
 * Resumen legible en el registro del Job.
 *
 * El resumen que k6 imprime por defecto es correcto y largo. Este añade
 * delante las tres cifras de las que depende la promoción, para que quien lea
 * `kubectl logs` de un análisis fallido vea en la primera pantalla cuál de los
 * tres umbrales se rompió.
 */
export function handleSummary(datos) {
  const m = datos.metrics;
  const err = (m.tasa_de_error?.values?.rate ?? 0) * 100;
  const p95 = m.http_req_duration?.values?.['p(95)'] ?? 0;
  const p99 = m.http_req_duration?.values?.['p(99)'] ?? 0;
  const total = m.http_reqs?.values?.count ?? 0;

  const linea = (etiqueta, valor, umbral, ok) =>
    `  ${ok ? '✓' : '✗'} ${etiqueta.padEnd(22)} ${valor.padEnd(12)} umbral ${umbral}\n`;

  const veredicto =
    `\n── CARGA contra ${BASE}\n` +
    `   ${total} peticiones · ${VUS} usuarios virtuales · ${DURACION}\n\n` +
    linea('tasa de error', `${err.toFixed(2)} %`, `< ${(UMBRAL_ERRORES * 100).toFixed(2)} %`, err < UMBRAL_ERRORES * 100) +
    linea('latencia p95', `${p95.toFixed(0)} ms`, `< ${UMBRAL_P95} ms`, p95 < UMBRAL_P95) +
    linea('latencia p99', `${p99.toFixed(0)} ms`, `< ${UMBRAL_P99} ms`, p99 < UMBRAL_P99) +
    '\n';

  return {
    stdout: veredicto,
    // El reporte completo en JSON, para adjuntarlo como evidencia. El Job lo
    // deja en su registro y `scripts/05-recoger-evidencia.sh` lo extrae.
    'resumen.json': JSON.stringify(datos, null, 2),
  };
}
