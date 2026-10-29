gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

local json = require "json"

local font = resource.load_font "font.ttf"
local logo = resource.load_image "logo.png"

-- Couleurs E.Leclerc (approximatives)
local BLEU   = {0.00, 0.36, 0.67}
local ORANGE = {0.97, 0.58, 0.12}
local ROUGE  = {0.85, 0.10, 0.10}
local BLANC  = {1, 1, 1}
local NOIR   = {0.10, 0.10, 0.10}

-- Couleurs des icones meteo
local SOLEIL = {1.00, 0.78, 0.17}
local NUAGE  = {0.75, 0.79, 0.83}
local GOUTTE = {0.49, 0.78, 1.00}

local function texture(c, a)
  return resource.create_colored_texture(c[1], c[2], c[3], a or 1)
end

local tex_blanc   = texture(BLANC)
local tex_bleu    = texture(BLEU)
local tex_rouge   = texture(ROUGE)
local tex_soleil  = texture(SOLEIL)
local tex_nuage   = texture(NUAGE)
local tex_goutte  = texture(GOUTTE)
local tex_bandeau = resource.create_colored_texture(0, 0, 0, 0.25)   -- assombrit le fond derriere la date

-- Rectangle aux coins gauches arrondis (le cote droit touche le bord de l'ecran)
local shader_arrondi = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float w, h, rayon;   // en pixels
  uniform float r, g, b;
  void main() {
    vec2 p = TexCoord * vec2(w, h);
    float a = 1.0;
    if (p.x < rayon) {
      float d = length(p - vec2(rayon, clamp(p.y, rayon, h - rayon)));
      a = clamp(rayon - d + 0.5, 0.0, 1.0);
    }
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(r, g, b, a);
  }
]]

-- Disque lisse dessine par un shader (pas d'image necessaire).
-- "coupe" retire un second disque : sert a dessiner le croissant de lune.
local shader_disque = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float flou;
  uniform float r, g, b;
  uniform float ox, oy, rc;
  void main() {
    vec2 p = (TexCoord - vec2(0.5)) * 2.0;
    float a = 1.0 - smoothstep(1.0 - flou, 1.0, length(p));
    a *= smoothstep(rc - flou, rc, length(p - vec2(ox, oy)));
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(r, g, b, a);
  }
]]

-- Fond bleu en degrade vertical : fonce en haut et en bas, plus clair au centre
local shader_fond = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  void main() {
    float t = 1.0 - abs(TexCoord.y * 2.0 - 1.0);
    vec3 bord   = vec3(0.000, 0.188, 0.369);
    vec3 milieu = vec3(0.047, 0.408, 0.722);
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(mix(bord, milieu, t), 1.0);
  }
]]

-- Chiffre d'afficheur LED 7 segments : segments biseautes, inclines, rouges.
-- Unites internes : chiffre de 20 x 40, segments de 4.4 d'epaisseur.
local LED_X0, LED_XW, LED_Y0, LED_YH = -3.0, 31.6, -3.0, 46.0   -- zone dessinee autour du chiffre
local shader_chiffre = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float sa, sb, sc, sd, se, sf, sg;   // 1 = segment allume
  uniform float px;                           // taille d'un pixel en unites
  const float W = 20.0;
  const float H = 40.0;
  const float T = 4.4;
  const float G = 1.1;
  const float K = 0.14;                       // inclinaison (environ 8 degres)

  float couvre(float d) { return clamp(d / px + 0.5, 0.0, 1.0); }

  float hseg(vec2 p, vec2 o) {
    vec2 q = p - o;
    float L = W - 2.0 * G;
    float demi = min(T * 0.5, min(q.x, L - q.x));
    return couvre(demi - abs(q.y));
  }

  float vseg(vec2 p, vec2 o) {
    vec2 q = p - o;
    float L = H * 0.5 - 2.0 * G;
    float demi = min(T * 0.5, min(q.y, L - q.y));
    return couvre(demi - abs(q.x));
  }

  void main() {
    vec2 p = vec2(-3.0 + TexCoord.x * 31.6, -3.0 + TexCoord.y * 46.0);
    p.x -= (H - p.y) * K;
    float a = hseg(p, vec2(G, 0.0));
    float g = hseg(p, vec2(G, H * 0.5));
    float d = hseg(p, vec2(G, H));
    float f = vseg(p, vec2(0.0, G));
    float b = vseg(p, vec2(W, G));
    float e = vseg(p, vec2(0.0, H * 0.5 + G));
    float c = vseg(p, vec2(W, H * 0.5 + G));
    float tout    = max(max(max(a, b), max(c, d)), max(max(e, f), g));
    float allume  = max(max(max(a * sa, b * sb), max(c * sc, d * sd)),
                        max(max(e * se, f * sf), g * sg));
    vec3 eteint = vec3(0.124, 0.039, 0.035);
    vec3 rouge  = vec3(1.00, 0.165, 0.10);
    vec3 col = mix(eteint, rouge, allume / max(tout, 0.001));
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(col, tout);
  }
]]

-- Panneau danger : triangle jaune a bord rouge et coins arrondis
local shader_panneau = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float bord;    // epaisseur du bord rouge (unites du carre -1..1)
  uniform float px;      // taille d'un pixel (memes unites)
  uniform float alpha;

  float triangle(vec2 p, float r) {
    const float k = 1.7320508;
    p.x = abs(p.x) - r;
    p.y = p.y + r / k;
    if (p.x + k * p.y > 0.0) p = vec2(p.x - k * p.y, -k * p.x - p.y) / 2.0;
    p.x -= clamp(p.x, -2.0 * r, 0.0);
    return -length(p) * sign(p.y);
  }

  void main() {
    vec2 p = vec2(TexCoord.x * 2.0 - 1.0, 1.0 - TexCoord.y * 2.0);
    p.y += 0.231;                               // centre le triangle dans le carre
    float d = triangle(p, 0.80) - 0.08;         // coins arrondis
    float dedans = clamp(-d / px + 0.5, 0.0, 1.0);
    float jaune  = clamp((-d - bord) / px + 0.5, 0.0, 1.0);
    vec3 col = mix(vec3(0.85, 0.10, 0.10), vec3(1.0, 0.78, 0.17), jaune);
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(col, dedans * alpha);
  }
]]

local JOURS = {"DIMANCHE","LUNDI","MARDI","MERCREDI","JEUDI","VENDREDI","SAMEDI"}
local MOIS  = {"JANVIER","FÉVRIER","MARS","AVRIL","MAI","JUIN","JUILLET",
               "AOÛT","SEPTEMBRE","OCTOBRE","NOVEMBRE","DÉCEMBRE"}
local ALERTES = {
  verglas = "VERGLAS", orages = "ORAGES", vent = "VENT VIOLENT", tempete = "TEMPÊTE",
  neige = "NEIGE", brouillard = "BROUILLARD", canicule = "CANICULE", grand_froid = "GRAND FROID",
}
local METEO_PERIMEE = 2 * 3600   -- au-dela, la meteo n'est plus affichee

-- Reglages (modifiables depuis le tableau de bord info-beamer)
local trotteuse = true
local horloge_digitale = true
local mode_alerte = "auto"
local alerte_manuelle = "verglas"
local message = ""

util.json_watch("config.json", function(config)
  if config.trotteuse ~= nil then trotteuse = config.trotteuse end
  if config.horloge_digitale ~= nil then horloge_digitale = config.horloge_digitale end
  mode_alerte     = config.alertes or "auto"
  alerte_manuelle = config.alerte_manuelle or "verglas"
  message         = config.message or ""
end)

-- Meteo ecrite par le service (meteo.json), absente au premier demarrage
local meteo = nil

local function lire_meteo()
  local ok, donnees = pcall(function()
    return json.decode(resource.load_file "meteo.json")
  end)
  if ok and type(donnees) == "table" then meteo = donnees end
end

node.event("content_update", function(fichier)
  if fichier == "meteo.json" then lire_meteo() end
end)
lire_meteo()

-- Heure d'été européenne automatique (France)
local function jour_semaine(y, m, d)   -- 0 = dimanche
  local t = {0,3,2,5,0,3,5,2,6,4,2,4}
  if m < 3 then y = y - 1 end
  return (y + math.floor(y/4) - math.floor(y/100) + math.floor(y/400) + t[m] + d) % 7
end

local function decalage(utc)
  local debut = 3 * 10000 + (31 - jour_semaine(utc.year, 3, 31)) * 100 + 1
  local fin   = 10 * 10000 + (31 - jour_semaine(utc.year, 10, 31)) * 100 + 1
  local now   = utc.month * 10000 + utc.day * 100 + utc.hour
  if now >= debut and now < fin then return 7200 end
  return 3600
end

-- coupe = {dx, dy, rayon} en fractions du rayon (disque retire)
local function disque(cx, cy, rayon, c, coupe)
  coupe = coupe or {0, 0, 0}
  shader_disque:use{
    flou = 1.5 / rayon,
    r = c[1], g = c[2], b = c[3],
    ox = coupe[1], oy = coupe[2], rc = coupe[3],
  }
  tex_blanc:draw(cx - rayon, cy - rayon, cx + rayon, cy + rayon)
  shader_disque:deactivate()
end

local function cartouche_gauche(x1, y1, x2, y2, c, rayon)
  shader_arrondi:use{w = x2 - x1, h = y2 - y1, rayon = rayon, r = c[1], g = c[2], b = c[3]}
  tex_blanc:draw(x1, y1, x2, y2)
  shader_arrondi:deactivate()
end

-- Rectangle tourne autour de (cx, cy) (angle en degres, 0 = vers le haut)
-- de "debut" a "fin" le long de cette direction (negatif = cote oppose)
local function trait(cx, cy, angle, debut, fin, largeur, tex)
  gl.pushMatrix()
  gl.translate(cx, cy)
  gl.rotate(angle, 0, 0, 1)
  tex:draw(-largeur / 2, -fin, largeur / 2, -debut)
  gl.popMatrix()
end

-- Barre aux bouts arrondis de (x1, y1) a (x2, y2)
local function barre(x1, y1, x2, y2, largeur, tex, c)
  local dx, dy = x2 - x1, y2 - y1
  trait(x1, y1, math.deg(math.atan2(dx, -dy)), 0, math.sqrt(dx * dx + dy * dy), largeur, tex)
  disque(x1, y1, largeur / 2, c)
  disque(x2, y2, largeur / 2, c)
end

local function centre(texte, x, y, taille, c, a)
  local w = font:width(texte, taille)
  font:write(x - w / 2, y - taille / 2, texte, taille, c[1], c[2], c[3], a or 1)
end

------------------------------------------------------------------------
-- Cadran
------------------------------------------------------------------------

local function cadran(cx, cy, R)
  -- Lunette orange, face blanche
  disque(cx, cy, R, ORANGE)
  disque(cx, cy, R * 0.95, BLANC)

  -- Graduations : minutes fines, heures epaisses
  for i = 0, 59 do
    if i % 5 == 0 then
      trait(cx, cy, i * 6, R * 0.80, R * 0.91, R * 0.022, tex_bleu)
    else
      trait(cx, cy, i * 6, R * 0.87, R * 0.91, R * 0.007, tex_bleu)
    end
  end

  for h = 1, 12 do
    local a = math.rad(h * 30)
    centre(tostring(h), cx + math.sin(a) * R * 0.68, cy - math.cos(a) * R * 0.68,
           R * 0.15, BLEU)
  end
end

local function logo_cadran(cx, cy, R)
  local iw, ih = logo:size()
  local lw = R * 0.80
  local lh = lw * ih / iw
  local y  = cy - R * 0.36 - lh / 2
  logo:draw(cx - lw / 2, y, cx + lw / 2, y + lh)
end

-- Aiguille aux deux bouts arrondis
local function aiguille(cx, cy, angle, debut, fin, largeur, tex, c)
  trait(cx, cy, angle, debut, fin, largeur, tex)
  local a = math.rad(angle)
  local sx, sy = math.sin(a), -math.cos(a)
  disque(cx + sx * fin,   cy + sy * fin,   largeur / 2, c)
  disque(cx + sx * debut, cy + sy * debut, largeur / 2, c)
end

local function aiguilles(cx, cy, R, d)
  local m = d.min + d.sec / 60
  local h = (d.hour % 12) + m / 60

  aiguille(cx, cy, h * 30, -R * 0.10, R * 0.50, R * 0.075, tex_bleu, BLEU)
  aiguille(cx, cy, m * 6,  -R * 0.12, R * 0.78, R * 0.035, tex_bleu, BLEU)
  disque(cx, cy, R * 0.07, BLEU)

  if trotteuse then
    aiguille(cx, cy, d.sec * 6, -R * 0.20, R * 0.86, R * 0.012, tex_rouge, ROUGE)
    disque(cx, cy, R * 0.035, ROUGE)
  end
end

------------------------------------------------------------------------
-- Dates de part et d'autre du cadran
------------------------------------------------------------------------

-- Mois/annee a gauche et jour/quantieme a droite, sur un bandeau sombre.
-- Renvoie le haut et le bas du bandeau.
local GRAND = 1.8

local function dates_cotes(cote, cy, d)
  local gauche = {MOIS[d.month], tostring(d.year)}
  local droite = {JOURS[d.wday], tostring(d.day)}

  local max_w = cote * 0.82
  local taille = HEIGHT * 0.075
  for _, texte in ipairs{gauche[1], droite[1]} do
    local w = font:width(texte, taille)
    if w > max_w then taille = taille * max_w / w end
  end
  local w = font:width(gauche[2], taille * GRAND)
  if w > max_w then taille = taille * max_w / w end
  local grand = taille * GRAND

  local ecart = taille * 0.25
  local marge = taille * 0.40
  local haut  = cy - (taille + ecart + grand) / 2
  local bas   = haut + taille + ecart + grand
  tex_bandeau:draw(0, haut - marge, WIDTH, bas + marge)

  local y1 = haut + taille / 2
  local y2 = bas - grand / 2
  local xg = cote / 2
  local xd = WIDTH - cote / 2
  centre(gauche[1], xg, y1, taille, BLANC)
  centre(gauche[2], xg, y2, grand,  BLANC)
  centre(droite[1], xd, y1, taille, BLANC)
  centre(droite[2], xd, y2, grand,  BLANC)
  return haut - marge, bas + marge
end

------------------------------------------------------------------------
-- Afficheur LED (bas droite)
------------------------------------------------------------------------

local SEGMENTS = {
  ["0"] = "abcdef", ["1"] = "bc",    ["2"] = "abged", ["3"] = "abgcd",   ["4"] = "fgbc",
  ["5"] = "afgcd",  ["6"] = "afgedc", ["7"] = "abc",  ["8"] = "abcdefg", ["9"] = "abcfgd",
}
local LED_ROUGE  = {1.00, 0.165, 0.10}
local LED_ETEINT = {0.124, 0.039, 0.035}   -- a garder identique a "eteint" dans shader_chiffre
local LED_FOND   = {0.04, 0.04, 0.04}
local LED_PENTE  = 0.14
local LED_LARGEUR = 4 * 20 + 3 * 8 + 14 + 40 * LED_PENTE   -- en unites
local LED_HAUTEUR = 40
local LED_MARGE   = 7

-- Chiffre dont le coin haut gauche est en (x, y), s = pixels par unite
local function chiffre_led(ch, x, y, s)
  local on = SEGMENTS[ch]
  local u = {px = 1 / s}
  for seg in ("abcdefg"):gmatch(".") do
    u["s" .. seg] = on:find(seg) and 1 or 0
  end
  shader_chiffre:use(u)
  tex_blanc:draw(x + LED_X0 * s, y + LED_Y0 * s,
                 x + (LED_X0 + LED_XW) * s, y + (LED_Y0 + LED_YH) * s)
  shader_chiffre:deactivate()
end

-- Zone du bas a droite : la plus grande qui tient entre le bandeau, le bas
-- de l'ecran et la courbe du cadran. Renvoie x1, y1, x2, y2 et l'echelle.
local function zone_bas(cx, cy, R, bandeau_bas)
  local bas_h  = HEIGHT * 0.96
  local droite = WIDTH - HEIGHT * 0.03
  local demi_l = LED_LARGEUR / 2 + LED_MARGE
  local demi_h = LED_HAUTEUR / 2 + LED_MARGE
  local s_max  = (bas_h - bandeau_bas) / (2 * demi_h)
  local s = s_max
  for _ = 1, 5 do
    local haut = bas_h - 2 * demi_h * s
    local dy   = math.max(haut - cy, 0)
    local bord = cx + math.sqrt(math.max(R * R - dy * dy, 0)) + R * 0.07
    s = math.min(s_max, (droite - bord) / (2 * demi_l))
  end
  -- Meme taille qu'en V1, mais collee contre le bord droit de l'ecran
  local decale = WIDTH - droite
  return droite - 2 * demi_l * s + decale, bas_h - 2 * demi_h * s, WIDTH, bas_h, s
end

local function afficheur_led(heure, x1, y1, x2, y2, s, deux_points)
  cartouche_gauche(x1, y1, WIDTH, y2, LED_FOND, (y2 - y1) * 0.16)
  local x = x1 + LED_MARGE * s
  local y = y1 + LED_MARGE * s

  chiffre_led(heure:sub(1, 1), x,          y, s)
  chiffre_led(heure:sub(2, 2), x + 28 * s, y, s)
  chiffre_led(heure:sub(4, 4), x + 70 * s, y, s)
  chiffre_led(heure:sub(5, 5), x + 98 * s, y, s)

  local c = deux_points and LED_ROUGE or LED_ETEINT
  for _, py in ipairs{13, 29} do
    disque(x + (59 + (40 - py) * LED_PENTE) * s, y + py * s, 2.6 * s, c)
  end
end

------------------------------------------------------------------------
-- Meteo (bas gauche) : icones dessinees en unites, environ 46 x 46
------------------------------------------------------------------------

local function nuage(x, y, k, c, tex)
  disque(x - 9 * k, y + 2 * k, 8 * k, c)
  disque(x + 1 * k, y - 4 * k, 11 * k, c)
  disque(x + 11 * k, y + 2 * k, 8 * k, c)
  tex:draw(x - 9 * k, y + 2 * k, x + 11 * k, y + 10 * k)
end

local function soleil(x, y, k)
  for i = 0, 7 do
    local a = math.rad(i * 45)
    local sx, sy = math.sin(a), -math.cos(a)
    barre(x + sx * 18 * k, y + sy * 18 * k, x + sx * 23 * k, y + sy * 23 * k,
          3.6 * k, tex_soleil, SOLEIL)
  end
  disque(x, y, 13 * k, SOLEIL)
end

local function lune(x, y, k)
  disque(x, y, 13 * k, SOLEIL, {0.45, -0.35, 0.85})
end

local ICONES = {
  soleil = function(x, y, k) soleil(x, y, k) end,
  lune   = function(x, y, k) lune(x, y, k) end,
  eclaircies = function(x, y, k)
    soleil(x + 7 * k, y - 8 * k, k * 0.7)
    nuage(x - 3 * k, y + 6 * k, k, BLANC, tex_blanc)
  end,
  eclaircies_nuit = function(x, y, k)
    lune(x + 7 * k, y - 8 * k, k * 0.75)
    nuage(x - 3 * k, y + 6 * k, k, BLANC, tex_blanc)
  end,
  nuageux = function(x, y, k)
    nuage(x + 6 * k, y - 6 * k, k * 0.75, NUAGE, tex_nuage)
    nuage(x - 4 * k, y + 6 * k, k, BLANC, tex_blanc)
  end,
  pluie = function(x, y, k)
    nuage(x, y - 6 * k, k, BLANC, tex_blanc)
    for _, dx in ipairs{-12, 0, 12} do
      barre(x + dx * k, y + 9 * k, x + (dx - 4) * k, y + 20 * k, 3 * k, tex_goutte, GOUTTE)
    end
  end,
  neige = function(x, y, k)
    nuage(x, y - 6 * k, k, BLANC, tex_blanc)
    for _, p in ipairs{{-12, 12}, {0, 12}, {12, 12}, {-6, 20}, {6, 20}} do
      disque(x + p[1] * k, y + p[2] * k, 2.6 * k, BLANC)
    end
  end,
  orage = function(x, y, k)
    nuage(x, y - 6 * k, k, NUAGE, tex_nuage)
    local z = {{3, 3}, {-4, 12}, {4, 12}, {-3, 22}}
    for i = 1, 3 do
      barre(x + z[i][1] * k, y + z[i][2] * k, x + z[i + 1][1] * k, y + z[i + 1][2] * k,
            3.4 * k, tex_soleil, SOLEIL)
    end
  end,
  brouillard = function(x, y, k)
    for i, dy in ipairs{-12, -4, 4, 12} do
      local dx = (i % 2 == 0) and 4 or -4
      barre(x + (dx - 16) * k, y + dy * k, x + (dx + 16) * k, y + dy * k, 4.4 * k, tex_nuage, NUAGE)
    end
  end,
}

local function meteo_valide()
  return meteo and meteo.maj and os.time() - meteo.maj < METEO_PERIMEE
end

-- Icone et temperature cotes a cote, en bas a gauche : centrees verticalement
-- entre le bandeau et le bas de l'ecran, reduites si elles approchent le cadran.
-- Le symbole degre est dessine (anneau) : la police ne l'affiche pas sur le Pi.
local function afficher_meteo(cx, cy, R, bandeau_bas)
  if not meteo_valide() or not meteo.temperature then return end
  local dessin = ICONES[meteo.icone] or ICONES.nuageux
  local temp = string.format("%d", math.floor(meteo.temperature + 0.5))

  local h = (HEIGHT - bandeau_bas) * 0.72
  local yc = (bandeau_bas + HEIGHT) / 2
  local x1 = HEIGHT * 0.03
  local dy = math.max(yc - h / 2 - cy, 0)
  local x2 = cx - math.sqrt(math.max(R * R - dy * dy, 0)) - R * 0.07

  local k = h / 46
  local taille = h * 0.85
  local ecart = h * 0.06
  local total = 46 * k + ecart + font:width(temp, taille) + taille * 0.30
  if total > x2 - x1 then
    local f = (x2 - x1) / total
    k, taille, ecart = k * f, taille * f, ecart * f
  end
  dessin(x1 + 23 * k, yc, k)

  local xt = x1 + 46 * k + ecart
  local yt = yc - taille / 2
  font:write(xt, yt, temp, taille, 1, 1, 1, 1)
  local rd = taille * 0.11
  disque(xt + font:width(temp, taille) + taille * 0.04 + rd, yt + taille * 0.22, rd, BLANC, {0, 0, 0.55})
end

------------------------------------------------------------------------
-- Alerte (haut gauche) et message (haut droite)
------------------------------------------------------------------------

local function alerte_active()
  if mode_alerte == "off" then return nil end
  if mode_alerte == "manuelle" then return ALERTES[alerte_manuelle] end
  if meteo_valide() and meteo.alerte then return ALERTES[meteo.alerte] end
  return nil
end

local function afficher_alerte(xc, cote, haut_max)
  local texte = alerte_active()
  if not texte then return end

  local taille_t = HEIGHT * 0.045
  local w = font:width(texte, taille_t)
  if w > cote * 0.9 then taille_t = taille_t * cote * 0.9 / w end

  local y = HEIGHT * 0.04
  local T = math.min(HEIGHT * 0.20, cote * 0.6, haut_max - y - taille_t * 1.4)
  local a = 0.675 + 0.325 * math.cos(sys.now() * 2 * math.pi / 1.6)   -- pulsation douce

  shader_panneau:use{bord = 0.14, px = 2 / T, alpha = a}
  tex_blanc:draw(xc - T / 2, y, xc + T / 2, y + T)
  shader_panneau:deactivate()
  centre("!", xc, y + T * 0.58, T * 0.48, NOIR, a)
  centre(texte, xc, y + T + taille_t * 0.8, taille_t, SOLEIL)
end

-- Decoupe le texte en lignes d'au plus "largeur" pixels
local function couper(texte, taille, largeur)
  local lignes, ligne = {}, ""
  for mot in texte:gmatch("%S+") do
    local essai = ligne == "" and mot or ligne .. " " .. mot
    if ligne ~= "" and font:width(essai, taille) > largeur then
      lignes[#lignes + 1] = ligne
      ligne = mot
    else
      ligne = essai
    end
  end
  if ligne ~= "" then lignes[#lignes + 1] = ligne end
  return lignes
end

-- Cartouche blanc colle au bord droit, coins gauches arrondis, texte bleu ;
-- centre verticalement entre le haut de l'ecran et le bandeau
local function afficher_message(cote, bandeau_haut)
  if not message:find("%S") then return end

  local larg   = cote * 0.97
  local x      = WIDTH - larg
  local pad    = HEIGHT * 0.025
  local h_max  = bandeau_haut - 2 * HEIGHT * 0.035
  local taille = HEIGHT * 0.10
  local lignes
  for _ = 1, 20 do
    lignes = couper(message, taille, larg - 2 * pad)
    local plus_large = 0
    for _, l in ipairs(lignes) do plus_large = math.max(plus_large, font:width(l, taille)) end
    local hauteur = #lignes * taille * 1.15 + 2 * pad
    if #lignes <= 3 and plus_large <= larg - 2 * pad and hauteur <= h_max then break end
    taille = taille * 0.92
  end

  local hauteur = #lignes * taille * 1.15 + 2 * pad
  local y = (bandeau_haut - hauteur) / 2
  cartouche_gauche(x, y, WIDTH, y + hauteur, BLANC, math.min(hauteur * 0.18, HEIGHT * 0.04))
  for i, l in ipairs(lignes) do
    centre(l, x + larg / 2, y + pad + (i - 0.5) * taille * 1.15, taille, BLEU)
  end
end

------------------------------------------------------------------------

function node.render()
  gl.clear(BLEU[1], BLEU[2], BLEU[3], 1)

  -- Fond en degrade
  shader_fond:use{}
  tex_blanc:draw(0, 0, WIDTH, HEIGHT)
  shader_fond:deactivate()

  -- Heure locale
  local t   = os.time()
  local utc = os.date("!*t", t)
  local d   = os.date("!*t", t + decalage(utc))

  -- Le cadran occupe toute la hauteur
  local cx, cy = WIDTH / 2, HEIGHT / 2
  local R = math.min(HEIGHT * 0.455, WIDTH * 0.48)
  local cote = cx - R                 -- largeur libre de chaque cote

  local bandeau_haut, bandeau_bas = dates_cotes(cote, cy, d)
  local haut_max = bandeau_haut - HEIGHT * 0.03

  -- Bas : heure LED a droite (optionnelle), meteo a gauche
  if horloge_digitale then
    local x1, y1, x2, y2, s = zone_bas(cx, cy, R, bandeau_bas)
    afficheur_led(string.format("%02d:%02d", d.hour, d.min), x1, y1, x2, y2, s, d.sec % 2 == 0)
  end
  afficher_meteo(cx, cy, R, bandeau_bas)

  -- Haut : alerte a gauche, message a droite
  afficher_alerte(cote / 2, cote, haut_max)
  afficher_message(cote, bandeau_haut)

  cadran(cx, cy, R)
  logo_cadran(cx, cy, R)
  aiguilles(cx, cy, R, d)
end
