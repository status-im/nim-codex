import std/osproc
import std/httpclient
import std/json
import pkg/asynctest
import pkg/chronos
import ./integration/nodes

suite "Integration tests":

  var node1, node2: Process
  var baseurl1, baseurl2: string
  var client: HttpClient

  setup:
    node1 = startNode ["--api-port=8080", "--udp-port=8090"]
    node2 = startNode ["--api-port=8081", "--udp-port=8091"]
    baseurl1 = "http://localhost:8080/api/dagger/v1"
    baseurl2 = "http://localhost:8081/api/dagger/v1"
    client = newHttpClient()

  teardown:
    client.close()
    node1.stop()
    node2.stop()

  test "nodes can print their peer information":
    let info1 = client.get(baseurl1 & "/info").body
    let info2 = client.get(baseurl2 & "/info").body
    check info1 != info2

  test "node accepts file uploads":
    let url = baseurl1 & "/upload"
    let response = client.post(url, "some file contents")
    check response.status == "200 OK"

  test "node handles new storage availability":
    let url = baseurl1 & "/sales/availability"
    let json = %*{"size": "0x1", "duration": "0x2", "minPrice": "0x3"}
    check client.post(url, $json).status == "200 OK"

  test "node lists storage that is for sale":
    let url = baseurl1 & "/sales/availability"
    let json = %*{"size": "0x1", "duration": "0x2", "minPrice": "0x3"}
    let availability = parseJson(client.post(url, $json).body)
    let response = client.get(url)
    check response.status == "200 OK"
    check parseJson(response.body) == %*[availability]

  test "node handles storage request":
    let cid = client.post(baseurl1 & "/upload", "some file contents").body
    let url = baseurl1 & "/storage/request/" & cid
    let json = %*{"duration": "0x1", "maxPrice": "0x2"}
    let response = client.post(url, $json)
    check response.status == "200 OK"

  test "node retrieves purchase status":
    let cid = client.post(baseurl1 & "/upload", "some file contents").body
    let request = %*{"duration": "0x1", "maxPrice": "0x2"}
    let id = client.post(baseurl1 & "/storage/request/" & cid, $request).body
    let response = client.get(baseurl1 & "/storage/purchases/" & id)
    check response.status == "200 OK"
    let json = parseJson(response.body)
    check json["request"]["ask"]["duration"].getStr == "0x1"
    check json["request"]["ask"]["maxPrice"].getStr == "0x2"
