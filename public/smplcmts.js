(async function () {
  var container = document.getElementById('smplcmts')
  if (container == null) {
    document.write('<section id="smplcmts"></div>')
    container = document.getElementById('smplcmts')
  }
  container.innerHTML = '<div></div><p></p><form></form>'
  var comments = container.getElementsByTagName('div')[0]
  var form = container.getElementsByTagName('form')[0]
  var message = container.getElementsByTagName('p')[0]
  var script = new URL(document.currentScript.src)
  var base = script.protocol + '//' + script.host
  var url = location.protocol + '//' + location.host + location.pathname
  class HTTPException extends Error {}
  async function load(method, path, body) {
    var params = {}
    params.headers = {}
    params.credentials = 'include'
    if (body) {
      params.headers['Content-Type'] = 'application/x-www-form-urlencoded'
      params.body = new URLSearchParams(body)
    }
    params.method = method
    var response = await fetch(base + path, params)
    var text = await response.text()
    if ( ! response.ok ) throw new HTTPException(text)
    return text
  }
  comments.outerHTML = await load('get', '/comments?url='+url)
  comments = container.getElementsByTagName('div')[0]
  form.outerHTML = await load('get', '/publish?url='+url)
  form = container.getElementsByTagName('form')[0]
  container.addEventListener("submit", async function (e) {
    e.preventDefault()
    e.stopPropagation()
    let action = e.target.attributes.action.value
    let method = e.target.attributes.method.value
    try {
      var formdata = new FormData(e.target)
      formdata.set('url', url)
      message.innerText = await load(method, action, formdata)
      form.outerHTML = await load('get', '/publish?url='+url)
      form = container.getElementsByTagName('form')[0]
      if (action == '/publish') {
        comments.outerHTML = await load('get', '/comments?url='+url)
        comments = container.getElementsByTagName('div')[0]
      }
    } catch (e) {
      if ( ! e instanceof HTTPException) throw e
      message.innerText=e.message
    }
  })
  container.addEventListener("click", async function (e) {
    var target
    if (e.target.tagName == 'A')
      target = e.target
    else if (e.target.parentNode.tagName == 'A')
      target = e.target.parentNode
    else
      return true
    if ( ! target.attributes.method ) return true
    e.preventDefault()
    e.stopPropagation()
    let href = target.attributes.href.value
    let method = target.attributes.method.value
    message.innerText = await load(method, href)
    form.outerHTML = await load('get', '/publish?url='+url)
    form = container.getElementsByTagName('form')[0]
    comments.outerHTML = await load('get', '/comments?url='+url)
    comments = container.getElementsByTagName('div')[0]
  })
  container.addEventListener("input", async function (e) {
    if (e.target.tagName != "TEXTAREA") return true
    await load('put', '/cache/comment', {
      comment: e.target.value,
      url: url
    })
  })
})()
