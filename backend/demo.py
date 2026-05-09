import requests
import urllib.parse
URL = 'http://127.0.0.1:8000/playlist-info?url=' + urllib.parse.quote('https://www.youtube.com/watch?v=Ffl10OT5dhQ&list=RDh_vArw1IYTg&index=3')
print(URL)
res = requests.get(URL)
print(res.text)
