"use strict";
var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
Object.defineProperty(exports, "__esModule", { value: true });
const utils_1 = require("../../data/utils");
const wdfpData_1 = require("../../data/wdfpData");
// fields that can be live-edited through the web UI
const editableNumericFields = [
    "vmoney", "freeVmoney", "freeMana", "paidMana", "starCrumb",
    "bondToken", "rankPoint", "stamina", "boostPoint", "bossBoostPoint", "expPool"
];
const editableStringFields = ["name", "comment"];
const liveEditState = (player) => ({
    name: player.name,
    comment: player.comment,
    vmoney: player.vmoney,
    freeVmoney: player.freeVmoney,
    freeMana: player.freeMana,
    paidMana: player.paidMana,
    starCrumb: player.starCrumb,
    bondToken: player.bondToken,
    rankPoint: player.rankPoint,
    stamina: player.stamina,
    boostPoint: player.boostPoint,
    bossBoostPoint: player.bossBoostPoint,
    expPool: player.expPool
});
const defaultPerPage = 25;
const routes = (fastify) => __awaiter(void 0, void 0, void 0, function* () {
    fastify.get("/", (request, reply) => __awaiter(void 0, void 0, void 0, function* () {
        // get page and perPage
        const { page, perPage } = request.query;
        const parsedPage = page === undefined ? 0 : Number.parseInt(page);
        const parsedPerPage = perPage === undefined ? defaultPerPage : Number.parseInt(perPage);
        if (isNaN(parsedPage) || isNaN(parsedPerPage))
            return reply.status(400).send({
                "error": "Bad Request",
                "message": "Invalid query parameters."
            });
        // get players
        const players = (0, wdfpData_1.getAllPlayersSync)(parsedPage * parsedPerPage, Math.min(defaultPerPage, parsedPerPage));
        return reply.status(200).send(players);
    }));
    fastify.get("/save", (request, reply) => __awaiter(void 0, void 0, void 0, function* () {
        // get id
        const { id } = request.query;
        const playerId = Number(id);
        if (isNaN(playerId))
            return reply.redirect("/player");
        // get player
        const data = (0, utils_1.getClientSerializedData)(playerId, { serializeRushEventData: true });
        if (data === null)
            return reply.redirect("/player");
        // otherwise, send
        reply.header("content-disposition", "attachment; save.json");
        reply.type('application/json').send(data);
    }));
    fastify.get("/state", (request, reply) => __awaiter(void 0, void 0, void 0, function* () {
        // get id
        const { id } = request.query;
        const playerId = Number(id);
        if (isNaN(playerId))
            return reply.status(400).send({
                "error": "Bad Request",
                "message": "Invalid player id."
            });
        const player = (0, wdfpData_1.getPlayerSync)(playerId);
        if (player === null)
            return reply.status(404).send({
                "error": "Not Found",
                "message": "Player not found."
            });
        return reply.status(200).send(liveEditState(player));
    }));
    fastify.post("/edit", (request, reply) => __awaiter(void 0, void 0, void 0, function* () {
        // get id
        const { id } = request.query;
        const playerId = Number(id);
        if (isNaN(playerId))
            return reply.status(400).send({
                "error": "Bad Request",
                "message": "Invalid player id."
            });
        const player = (0, wdfpData_1.getPlayerSync)(playerId);
        if (player === null)
            return reply.status(404).send({
                "error": "Not Found",
                "message": "Player not found."
            });
        const body = request.body;
        if (body === undefined || typeof body !== "object")
            return reply.status(400).send({
                "error": "Bad Request",
                "message": "Invalid request body."
            });
        // build the update from the editable field whitelist
        const changes = {};
        const entries = body;
        for (const key of Object.keys(entries)) {
            const value = entries[key];
            if (editableNumericFields.includes(key)) {
                const parsed = value;
                if (typeof parsed !== "number" || !Number.isSafeInteger(parsed) || 0 > parsed) {
                    return reply.status(400).send({
                        "error": "Bad Request",
                        "message": `Field "${key}" must be a non-negative integer.`
                    });
                }
                changes[key] = parsed;
            }
            else if (editableStringFields.includes(key)) {
                const parsed = value;
                if (typeof parsed !== "string" || 100 < parsed.length) {
                    return reply.status(400).send({
                        "error": "Bad Request",
                        "message": `Field "${key}" must be a string of at most 100 characters.`
                    });
                }
                changes[key] = parsed;
            }
        }
        if (Object.keys(changes).length === 0)
            return reply.status(400).send({
                "error": "Bad Request",
                "message": "No editable fields were provided."
            });
        (0, wdfpData_1.updatePlayerSync)(Object.assign({ id: playerId }, changes));
        return reply.status(200).send(liveEditState((0, wdfpData_1.getPlayerSync)(playerId)));
    }));
    fastify.post("/save", (request, reply) => __awaiter(void 0, void 0, void 0, function* () {
        // get id
        const { id } = request.query;
        const playerId = Number(id);
        if (isNaN(playerId))
            return reply.redirect("/player");
        try {
            // get file
            const file = yield request.file();
            if (file === undefined)
                return reply.redirect(`/player/${id}`);
            const text = (yield file.toBuffer()).toString('utf-8');
            const json = JSON.parse(text);
            const saveData = json['data'] === undefined ? json : json['data'];
            const parsedData = (0, utils_1.deserializePlayerData)(playerId, saveData);
            (0, wdfpData_1.replacePlayerDataSync)(parsedData);
        }
        catch (error) {
            return reply.redirect(`/player/${id}?error=${error}`);
        }
        return reply.redirect(`/player/${id}`);
    }));
});
exports.default = routes;
