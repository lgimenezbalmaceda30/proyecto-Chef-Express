# Chefexprés · Trazabilidad

> Para arquitectura completa, estado del proyecto, auditoría de seguridad y
> pendientes reales, ver [`CLAUDE.md`](./CLAUDE.md) — es el documento de
> referencia, este README es solo la puerta de entrada rápida.

Sistema de trazabilidad alimentaria para Chefexprés: registra el recorrido
completo de un producto — ingreso de materia prima → relleno → masa →
semielaborado → producto terminado — además de limpieza de zonas e insumos
de limpieza, con control de permisos por usuario.

Es una PWA de una sola página (`index.html`), sin build step: React,
ReactDOM, Babel standalone y el cliente de Supabase se cargan por CDN y el
JSX se transpila en el navegador.

## Estructura

- `index.html` — toda la app (UI, lógica y capa de sincronización con Supabase).
- `sw.js` — Service Worker (cachea el shell offline; HTML network-first, estáticos stale-while-revalidate).
- `manifest.json` — manifest de la PWA.
- `icon-*.png`, `apple-touch-icon.png`, `favicon*.png/.ico` — íconos de la app.
- `supabase/SCHEMA.md` — esquema de la base (tablas y columnas), documentado
  a mano a partir de un dump de Supabase. La base se administra manualmente
  desde el dashboard de Supabase, no hay migraciones automatizadas en este
  repo — ver ese archivo para cómo mantenerlo al día.

## Entornos (testing / producción)

El entorno se elige **según el hostname** (ver `HOSTS_PROD` en `index.html`):
cualquier dominio que no esté en esa lista cae automáticamente a `testing`,
para que sea imposible escribir datos de prueba en la base del cliente por
accidente. Cada entorno apunta a un proyecto de Supabase distinto (URL +
publishable key), definidos en el objeto `SUPA` dentro de `index.html`.

## Desarrollo local

No requiere instalación: es HTML estático.

```bash
python3 -m http.server 8080
# abrir http://localhost:8080
```

Como `localhost` no está en `HOSTS_PROD`, local siempre trabaja contra el
proyecto de Supabase de **testing**.

## Deploy

Pensado para Netlify (deploy del sitio estático, sin build command). Solo
el hostname `chefexpress.netlify.app` corre contra producción.
