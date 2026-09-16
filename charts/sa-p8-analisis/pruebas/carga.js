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
 *     en vuelo, y eso produce algún error aislado que no tiene nada que ver
 *     con el código. Poner el umbral en cero haría que el canary abortara por
 *     su propio funcionamiento —un falso positivo que enseña a la gente a
 *     ignorar la alarma—.
 *
 *     Un 1 % sobre las ~2670 peticiones de una corrida son 26 fallos: muy por
 *     encima de las dos o tres recargas esperables, y muy por debajo de lo que
 *     produce un defecto real.
 *
 *   · `UMBRAL_P95` (300 ms). La versión estable mide **9 ms** en este clúster
 *     (ver `P8/docs/evidencias/05-calibracion-linea-base.txt`). El umbral está
 *     treinta y tres veces por encima a propósito: la medición de referencia se
 *     tomó con la plataforma en reposo, y durante un canary el pod candidato
 *     está calentando sus pools de conexiones, nginx recarga su configuración
 *     en cada cambio de peso y los otros dos Jobs de análisis compiten por la
 *     CPU. Un umbral pegado a los 9 ms abortaría rollouts sanos.
 *
 *   · `UMBRAL_P99` (600 ms). Va aparte porque captura algo que el p95 esconde:
 *     una degradación que afecta solo a una de cada cien peticiones. Sin él,
 *     un defecto que toca el 1 % del tráfico pasaría las tres puertas. La
 *     línea base es de 22 ms.
 *
 * Los tres son umbrales `abortOnFail`, así que k6 termina en cuanto uno se
 * rompe en lugar de gastar los 90 segundos completos. El canary aborta antes
 * y el porcentaje de usuarios afectados es menor.
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const SERVICIO = __ENV.SERVICIO_CANARY;
const NAMESPACE = __ENV.NAMESPACE;
const PUERTO = __ENV.PUERTO || '8080';
const BASE = `http://${SERVICIO}.${NAMESPACE}.svc.cluster.local:${PUERTO}`;

const UMBRAL_ERRORES = __ENV.UMBRAL_ERRORES || '0.01';
const UMBRAL_P95 = __ENV.UMBRAL_P95 || '300';
const UMBRAL_P99 = __ENV.UMBRAL_P99 || '600';
const VUS = parseInt(__ENV.VUS || '15', 10);
const DURACION = __ENV.DURACION || '90s';

// Cuánto se genera carga ANTES de empezar a medir. Ver el comentario extenso
// sobre los dos escenarios, más abajo: sin esta fase, el p95 de las primeras
// muestras es el del pod arrancando y la prueba rechaza versiones sanas.
const CALENTAMIENTO = __ENV.CALENTAMIENTO || '15s';

// Métricas propias. Separar la latencia por tipo de petición evita que el
// promedio mezcle una consulta GraphQL con una sonda de salud y esconda cuál
// de las dos se degradó —que es justo lo que hay que saber para el informe de
// incidente—.
const latenciaSalud = new Trend('latencia_salud', true);
const latenciaCatalogo = new Trend('latencia_catalogo', true);
const tasaError = new Rate('tasa_de_error');

// Contador delator. El gateway limita peticiones por IP y k6 llega desde una
// sola: si la prueba empuja más de lo que el límite permite, el gateway
// responde 429 barato y la medición deja de ser sobre la aplicación.
//
// Sin esta métrica el síntoma es desconcertante —una tasa de error alta y
// estable que no se corresponde con nada roto—; con ella, el veredicto dice
// exactamente qué pasó. Se descubrió así: la corrida de calibración marcaba un
// 37 % de error constante mientras las mismas peticiones, sueltas, devolvían
// 200.
const respuestas429 = new Counter('respuestas_429');

export const options = {
  // ═══════════════════════════════════════════════════════════════════════
  //  DOS FASES: CALENTAMIENTO Y MEDICIÓN
  // ═══════════════════════════════════════════════════════════════════════
  //
  // La primera versión tenía un solo escenario, y produjo un falso positivo
  // que conviene dejar escrito porque es el modo de fallo más caro que puede
  // tener una puerta de calidad.
  //
  // El canary promovía la versión `1.0.0` —sana, la misma que llevaba horas
  // corriendo— y el análisis la rechazó:
  //
  //     60 peticiones · 15 usuarios virtuales · 90s
  //     ✗ latencia p95   387 ms   umbral < 300 ms
  //
  // Sesenta peticiones. La prueba abortó a los dos segundos de empezar.
  //
  // La causa es la combinación de dos cosas correctas por separado. Con
  // `abortOnFail`, k6 evalúa el umbral CONTINUAMENTE desde la primera muestra;
  // y las primeras peticiones contra un pod recién creado son lentas por
  // naturaleza: hay que abrir la conexión TCP, llenar el pool de PostgreSQL,
  // establecer el canal con el broker y calentar el JIT de Node. Con sesenta
  // muestras, el p95 ES el arranque.
  //
  // El umbral no estaba mal: lo que estaba mal era el momento de medir. Una
  // prueba que penaliza a toda versión por arrancar rechaza también las sanas,
  // y un canary que rechaza versiones sanas enseña a promover a mano.
  //
  // La solución son dos escenarios. El primero genera carga durante quince
  // segundos y sus muestras llevan la etiqueta `fase: calentamiento`; el
  // segundo arranca después con `fase: medicion`. Los umbrales se aplican
  // SOLO a las muestras de la segunda fase.
  //
  // `delayAbortEval` es el cinturón además de los tirantes: impide que k6
  // evalúe el abort durante los primeros veinte segundos, cuando el umbral
  // etiquetado todavía no tiene ninguna muestra.
  scenarios: {
    calentamiento: {
      executor: 'constant-vus',
      vus: VUS,
      duration: CALENTAMIENTO,
      tags: { fase: 'calentamiento' },
    },
    medicion: {
      executor: 'constant-vus',
      vus: VUS,
      duration: DURACION,
      startTime: CALENTAMIENTO,
      tags: { fase: 'medicion' },
    },
  },

  thresholds: {
    'tasa_de_error{fase:medicion}': [
      { threshold: `rate<${UMBRAL_ERRORES}`, abortOnFail: true, delayAbortEval: '20s' },
    ],
    'http_req_duration{fase:medicion}': [
      { threshold: `p(95)<${UMBRAL_P95}`, abortOnFail: true, delayAbortEval: '20s' },
      { threshold: `p(99)<${UMBRAL_P99}`, abortOnFail: true, delayAbortEval: '20s' },
    ],

    // Ni un solo 429. No es un umbral de calidad de la versión candidata: es
    // una comprobación de que la prueba está midiendo lo que cree medir. Si
    // salta, el problema está en la prueba o en `RATE_LIMIT_MAX`, no en el
    // código bajo análisis.
    //
    // Sin etiquetar: un 429 durante el calentamiento también significa que
    // algo va mal con el limitador, y da igual en qué fase aparezca.
    respuestas_429: [{ threshold: 'count < 1', abortOnFail: true, delayAbortEval: '20s' }],
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
  respuestas429.add(salud.status === 429 ? 1 : 0);
  const saludOk = check(salud, {
    'salud responde 200': (r) => r.status === 200,
    'salud dice ok': (r) => r.status === 200 && r.json('status') === 'ok',
  });
  tasaError.add(!saludOk);

  // --- Catálogo: trabajo real, con base de datos detrás -------------------
  //
  // La ruta termina en `/graphql`. El gateway proxea `/api/catalog` con
  // `upstreamPrefix: ''`, así que reenvía la subruta tal cual, y Apollo escucha
  // en `/graphql`. Sin ese sufijo la petición llega como `POST /` y Express
  // devuelve 404 «Cannot POST /»: la prueba mediría un 50 % de error constante
  // que no tiene nada que ver con la versión bajo prueba.
  //
  // Es una lectura idempotente: se puede repetir miles de veces sin ensuciar
  // la base ni llenar la cola del broker. Una prueba de carga que creara
  // pedidos mediría lo mismo y dejaría decenas de miles de filas basura que el
  // consumidor tendría que drenar durante horas.
  const catalogo = http.post(`${BASE}/api/catalog/graphql`, CONSULTA_CATALOGO, params);
  latenciaCatalogo.add(catalogo.timings.duration);
  respuestas429.add(catalogo.status === 429 ? 1 : 0);
  const catalogoOk = check(catalogo, {
    'catálogo responde 200': (r) => r.status === 200,
    // GraphQL devuelve 200 aunque la consulta falle, con los errores dentro
    // del cuerpo. Sin esta segunda comprobación, un catálogo roto pasaría la
    // puerta con un 0 % de error.
    'catálogo devuelve productos': (r) => r.status === 200 && r.body.includes('"products"'),
    'catálogo sin errores GraphQL': (r) => r.status === 200 && !r.body.includes('"errors"'),
  });
  tasaError.add(!catalogoOk);

  // --- El ritmo ------------------------------------------------------------
  //
  // Sin esta pausa, k6 encadena iteraciones tan rápido como el servidor
  // responda: la primera calibración generó 94 000 peticiones en 90 segundos
  // —más de 1000 por segundo con 15 usuarios—. Eso no es una carga realista,
  // es un bucle cerrado, y mide el techo de rendimiento del gateway en lugar
  // de la latencia que percibiría un usuario.
  //
  // Peor para el propósito de esta prueba: a ese ritmo la latencia está
  // dominada por el encolamiento, así que TODA versión parece lenta y el
  // umbral p95 deja de distinguir la buena de la defectuosa.
  //
  // Un segundo por iteración, con 15 usuarios y dos peticiones cada una, da
  // unas 30 peticiones por segundo: ~2700 en los noventa segundos. Es la cifra
  // sobre la que está calculado el umbral del 1 % de errores.
  sleep(1);
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
  // Se leen las métricas ETIQUETADAS, que son sobre las que se evalúan los
  // umbrales. Leer las globales daría un número distinto del que decidió la
  // promoción —incluiría el calentamiento— y el veredicto impreso no
  // coincidiría con el veredicto real.
  const sub = (nombre) => m[`${nombre}{fase:medicion}`] ?? m[nombre];
  const err = (sub('tasa_de_error')?.values?.rate ?? 0) * 100;
  const dur = sub('http_req_duration')?.values ?? {};
  const p95 = dur['p(95)'] ?? 0;
  const p99 = dur['p(99)'] ?? 0;
  const total = sub('http_reqs')?.values?.count ?? m.http_reqs?.values?.count ?? 0;

  const linea = (etiqueta, valor, umbral, ok) =>
    `  ${ok ? '✓' : '✗'} ${etiqueta.padEnd(22)} ${valor.padEnd(12)} umbral ${umbral}\n`;

  const veredicto =
    `\n── CARGA contra ${BASE}\n` +
    `   ${total} peticiones medidas · ${VUS} usuarios virtuales\n` +
    `   ${CALENTAMIENTO} de calentamiento (descartado) + ${DURACION} de medición\n\n` +
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
