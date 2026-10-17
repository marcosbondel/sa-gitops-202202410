/**
 * usuarios.js — Clientes simulados de la tienda (Práctica 10)
 *
 * Esta plataforma no tiene usuarios reales. Sin tráfico, Prometheus no tiene
 * nada que medir: el SLI no existe, el presupuesto no se consume y el canary
 * no tiene con qué decidir. Este script hace de clientela, sin parar, por el
 * mismo camino que un cliente de verdad: el controlador de Ingress, con el
 * nombre del host de cada ambiente.
 *
 * ## En qué se diferencia de las pruebas del canary de la P8
 *
 * Las de la P8 eran una PUERTA: un Job que el análisis lanzaba contra el
 * Service canary y que devolvía sí o no. Esto no decide nada ni sabe que
 * existe un canary. Genera tráfico de fondo —el que en producción generarían
 * las personas— y el análisis mide, en Prometheus, cómo le fue a la parte
 * de ese tráfico que el Ingress mandó a la versión candidata. Si mañana
 * llegaran clientes reales, este Deployment se borra y el análisis sigue
 * funcionando igual.
 *
 * ## Dos tipos de cliente
 *
 *   navegador   manda `Accept-Language` (todos los navegadores lo hacen)
 *   app móvil   no la manda (un cliente HTTP mínimo)
 *
 * La proporción, 70/30, es la que hace visible el fallo inducido de la
 * versión 1.3.1-fallo del gateway: solo rompe a los que no mandan la cabecera.
 *
 * ## Lo que hace cada cliente
 *
 *   navegar   consulta el catálogo (la operación del SLO 2)
 *   comprar   inicia sesión, crea un pedido (la operación del SLO 1) y casi
 *             siempre lo paga; a veces lo cancela, y a veces pide un producto
 *             que no existe —un 400 legítimo que NO consume presupuesto—
 *
 * Cada corrida dura 10 minutos y el contenedor la repite en un bucle: la
 * sesión (JWT de 15 min) se renueva en cada vuelta, y k6 no acumula en
 * memoria las muestras de horas de ejecución.
 */
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE || 'http://ingress-nginx-controller.ingress-nginx.svc.cluster.local';
const HOST = __ENV.HOST;
const USUARIOS = parseInt(__ENV.USUARIOS || '8', 10);
const NAVEGAR_POR_SEGUNDO = parseInt(__ENV.NAVEGAR_POR_SEGUNDO || '3', 10);
const COMPRAS_POR_MINUTO = parseInt(__ENV.COMPRAS_POR_MINUTO || '30', 10);
const DURACION = __ENV.DURACION || '10m';
const PROPORCION_APP = parseFloat(__ENV.PROPORCION_APP || '0.3');

export const options = {
  discardResponseBodies: false,
  scenarios: {
    navegar: {
      executor: 'constant-arrival-rate',
      exec: 'navegar',
      rate: NAVEGAR_POR_SEGUNDO,
      timeUnit: '1s',
      duration: DURACION,
      preAllocatedVUs: 10,
      maxVUs: 50,
    },
    comprar: {
      executor: 'constant-arrival-rate',
      exec: 'comprar',
      rate: COMPRAS_POR_MINUTO,
      timeUnit: '1m',
      duration: DURACION,
      preAllocatedVUs: 5,
      maxVUs: 30,
    },
  },
};

const CONSULTA_CATALOGO = JSON.stringify({
  query: '{ products(limit: 12) { items { id sku name price currency active } total } }',
});

function cabeceras(extra) {
  const h = Object.assign({ Host: HOST, 'Content-Type': 'application/json' }, extra || {});
  // Un 30 % de los clientes son la app móvil, que no manda Accept-Language.
  if (Math.random() >= PROPORCION_APP) {
    h['Accept-Language'] = 'es-GT,es;q=0.9,en;q=0.8';
  }
  return h;
}

export function setup() {
  const sello = `${Date.now()}`;
  const sesiones = [];
  for (let i = 0; i < USUARIOS; i += 1) {
    const email = `cliente-${sello}-${i}@simulador.example.com`;
    const password = `Simulado-${sello}-${i}`;
    const base = { headers: { Host: HOST, 'Content-Type': 'application/json', 'Accept-Language': 'es-GT' } };
    http.post(`${BASE}/api/auth/register`,
      JSON.stringify({ full_name: `Cliente simulado ${i}`, email, password, role: 'Cliente' }), base);
    const r = http.post(`${BASE}/api/auth/login`, JSON.stringify({ email, password }), base);
    const cookie = r.cookies.access_token && r.cookies.access_token[0];
    if (cookie) sesiones.push(cookie.value);
  }

  const cat = http.post(`${BASE}/api/catalog/graphql`, CONSULTA_CATALOGO,
    { headers: { Host: HOST, 'Content-Type': 'application/json', 'Accept-Language': 'es-GT' } });
  let productos = [];
  try {
    productos = cat.json('data.products.items').filter((p) => p.active).map((p) => p.id);
  } catch (_) {
    productos = [];
  }
  return { sesiones, productos };
}

export function navegar() {
  const r = http.post(`${BASE}/api/catalog/graphql`, CONSULTA_CATALOGO, { headers: cabeceras(), tags: { operacion: 'catalogo' } });
  check(r, { 'catálogo 200': (x) => x.status === 200 });
}

function alAzar(lista) {
  return lista[Math.floor(Math.random() * lista.length)];
}

export function comprar(datos) {
  if (!datos.sesiones.length || !datos.productos.length) return;
  const sesion = { Cookie: `access_token=${alAzar(datos.sesiones)}` };

  // Un 4 % pide un producto que no existe: el sistema responde 400 y lo
  // cuenta como `pedidos_rechazados_total{motivo="producto_no_disponible"}`.
  // Es una compra perdida, pero NO un fallo del sistema: no toca el SLO.
  const inexistente = Math.random() < 0.04;
  const items = inexistente
    ? [{ product_id: '00000000-0000-4000-8000-000000000000', quantity: 1 }]
    : [{ product_id: alAzar(datos.productos), quantity: 1 + Math.floor(Math.random() * 3) }];

  const pedido = http.post(`${BASE}/api/orders`, JSON.stringify({ items }),
    { headers: cabeceras(sesion), tags: { operacion: 'checkout' } });
  check(pedido, { 'checkout sin error del sistema': (x) => x.status < 500 });
  if (pedido.status !== 201) return;

  const id = pedido.json('id');
  const suerte = Math.random();
  if (suerte < 0.8) {
    http.post(`${BASE}/api/orders/${id}/pay`, null, { headers: cabeceras(sesion), tags: { operacion: 'pago' } });
  } else if (suerte < 0.9) {
    http.post(`${BASE}/api/orders/${id}/cancel`, null, { headers: cabeceras(sesion), tags: { operacion: 'cancelacion' } });
  }
}
