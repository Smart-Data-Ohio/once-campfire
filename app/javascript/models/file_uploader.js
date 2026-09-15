export default class FileUploader {
  constructor(file, url, clientMessageId, progressCallback, reply = null) {
    this.file = file
    this.url = url
    this.clientMessageId = clientMessageId
    this.progressCallback = progressCallback
    this.reply = reply
  }

  upload() {
    const formdata = new FormData()
    formdata.append("message[attachment]", this.file)
    formdata.append("message[client_message_id]", this.clientMessageId)
    if (this.reply?.id) {
      formdata.append("message[reply_to_message_id]", this.reply.id)
      formdata.append("message[reply_notify_author]", this.reply.notify ? "1" : "0")
    }

    const req = new XMLHttpRequest()
    req.open("POST", this.url)
    req.setRequestHeader("X-CSRF-Token", document.querySelector("meta[name=csrf-token]").content)
    req.upload.addEventListener("progress", this.#uploadProgress.bind(this))

    const result = new Promise((resolve, reject) => {
      req.addEventListener("readystatechange", () => {
        if (req.readyState === XMLHttpRequest.DONE) {
          if (req.status < 400) {
            resolve(req.response)
          } else {
            reject()
          }
        }
      })
    })

    req.send(formdata)
    return result
  }

  #uploadProgress(event) {
    if (event.lengthComputable) {
      const percent = Math.round((event.loaded / event.total) * 100)
      this.progressCallback(percent, this.clientMessageId, this.file)
    }
  }
}
