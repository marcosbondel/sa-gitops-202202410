La práctica pide que el namespace `sa-p5` lo cree el chart y no una persona.
Se intentó exactamente eso —un `kind: Namespace` en las plantillas— y **Helm 3
no lo permite cuando el release se guarda en ese mismo namespace**.

## El orden de operaciones de `helm install`

    1. Renderiza las plantillas
    2. **Guarda el registro del release** (un Secret en el namespace de destino)
    3. Ejecuta los hooks de pre-install
    4. Aplica los manifiestos

El paso 2 ocurre antes que el 4. Instalar en un namespace que el propio chart
va a crear falla en el paso 2, antes de llegar a crearlo:

    $ helm install sa-platform ./charts/sa-platform -n sa-p5
    Error: INSTALLATION FAILED: create: failed to create: namespaces "sa-p5" not found

Se probó también declararlo como hook de `pre-install` con peso -100, por si el
paso 3 se adelantaba al 2. No se adelanta: el mismo error.

## Por qué tampoco sirve combinarlo con --create-namespace

`--create-namespace` crea el namespace **fuera** del release, sin las
anotaciones de propiedad de Helm. Cuando después se aplica el manifiesto del
chart, choca con un objeto que ya existe y que Helm no reconoce como suyo:

    Error: INSTALLATION FAILED: 1 error occurred:
        * namespaces "sa-p5" already exists

Helm 3.17 introdujo `--take-ownership` para adoptar recursos preexistentes, y
funcionaría. Se descartó porque ata la instalación a una versión reciente de
Helm por una ganancia cosmética: el namespace acabaría creado por el mismo
comando en ambos casos.

## Lo que se hace en su lugar

    helm install sa-platform ./charts/sa-platform -n sa-p5 --create-namespace ...

El namespace lo crea **Helm, durante el despliegue, en el mismo comando**.
Nunca se ejecuta `kubectl create namespace` ni ningún `kubectl apply -f`, que
es lo que la restricción busca evitar.

## La consecuencia, dicha en voz alta

Un namespace creado con `--create-namespace` **no forma parte del release**, así
que `helm uninstall` no se lo lleva. Queda vacío, con sus etiquetas por
defecto. Borrarlo es un paso explícito:

    helm uninstall sa-platform -n sa-p5
    kubectl delete namespace sa-p5

La ResourceQuota, el LimitRange y las NetworkPolicies **sí** son del release y
desaparecen con él, que era la parte que de verdad importaba: lo peligroso no
es un namespace vacío olvidado, sino una política de red huérfana que el
siguiente despliegue hereda sin saberlo.

