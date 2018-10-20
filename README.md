# servant-http2-client

This package provides a way to generate HTTP2 client code from
[Servant](http://haskell-servant.github.io/) API descriptions.

Please consider this package somewhat unstable. The author would appreciate
feedbacks and benchmarks in real-world deployments.

## Usage

The usage is pretty similar to `servant-client` but uses an HTTP2Client rather
than a Manager. See also the section below to highlight differences between
`servant-client` and `servant-http2-client`.

HTTP2 uses a flow-control mechanism, which `http2-client` exposes but
`servant-http2-client` hides: as a client you have nothing to do and
DATA-credit is immediately sent to the server. This mechanism is easy for the
user but effectively disables flow control at the application level. Further,
this easy-to-use mechanism may have some slight overhead for sending many small
control frames. Future version of the library will expose more control points
(at an increased cost).

You can find a full example at `./test/Spec.hs` .

## Differences with servant-client

The client leverages `http2-client` and hence behave slightly differently from
`servant-client`, which uses `http-client`. Most notably, HTTP/2 uses a single
TCP connection for performing concurrent requests, whereas HTTP/1.x at best
pipelines request sequentially over a same connection.

The `servant-client` library uses a connection Manager to create new TCP
connections or try re-using existing connections. This `servant-http2-client`
makes no use of such a Manager. This difference is mostly important for
load-balancing and unstable network environments. When targeting a
load-balanced server, a `servant-http2-client` will always hit the same
TCP-endpoint whereas a `servant-client` may hit different TCP-endpoint for each
request. Also, after handling a connection error, a `servant-client` will open
a new TCP connection without any decision from the programmer. Conversely, a
broken `servant-http2-client` will be of no practical use and the programmer
must create a new H2ClientEnv. A Manager abstraction may be added to
`http2-client` later.

The `servant-client` package offers Cookies handling, whereas
`servant-http2-client` has no such feature. Please consider opening a
pull-request for adding the support.

Finally, it's always good to remember that HTTP2 allows concurrent queries,
that is, many API calls may fail when a single TCP connection dies out.
