/*
 * Copyright (C) 2009,2010 Jens Georg <mail@jensge.org>.
 *
 * This file is part of Rygel.
 *
 * Rygel is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * Rygel is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
 */

using Gee;
using GUPnP;

internal class Rygel.MediaExportQueryContainer : Rygel.MediaDBContainer {
    public static const string PREFIX = "virtual-container:";
    private bool item_container;
    private string attribute;
    private SearchExpression expression;

    public MediaExportQueryContainer (MediaDB media_db,
                                      string  id,
                                      string  name) {
        // parse the id
        // Following the schema:
        // virtual-folder:<class> -> get all of that class (eg. Albums)
        // virtual-folder:<class>,<item> -> get all that is contained in that
        //                                  class
        // If an item suffix is present, the children are items, otherwise
        // containers
        // example: virtual-folder:upnp:album -> All albums
        //          virtual-folder:upnp:album,The White Album -> All tracks of
        //          the White Album
        //          virtual-folder:dc:creator,The Beatles,upnp:album ->
        //          All Albums by the Beatles
        //          the parts not prefixed by virtual-folder: are URL-escaped
        base (media_db, id, name);

        var args = id.split(",");



        // build SearchExpression from container-id
        int i = args.length - 1 - args.length % 2;
        while (i >= 1 - args.length % 2) {
            var exp = new RelationalExpression ();
            exp.operand1 = args[i - 1].replace (PREFIX, "");
            exp.op = SearchCriteriaOp.EQ;
            exp.operand2 = args[i];
            if (this.expression != null) {
                var exp2 = new LogicalExpression ();
                exp2.operand1 = this.expression;
                exp2.operand2 = exp;
                exp2.op = LogicalOperator.AND;
                this.expression = exp2;
            } else {
                this.expression = exp;
            }

            i -= 2;
        }

        if (args.length % 2 == 0) {
            // we will contain items
            this.item_container = true;
        } else {
            this.item_container = false;
            this.attribute = args[args.length - 1].replace (PREFIX, "");
        }
    }

    public override async Gee.List<MediaObject>? search (
                                        SearchExpression expression,
                                        uint             offset,
                                        uint             max_count,
                                        out uint         total_matches,
                                        Cancellable?     cancellable)
                                        throws GLib.Error {
        var combined_expression = new LogicalExpression ();
        combined_expression.operand1 = this.expression;
        combined_expression.op = LogicalOperator.AND;
        combined_expression.operand2 = expression;

        var max_objects = max_count;
        if (max_objects == 0) {
            max_objects = -1;
        }

        var children = this.media_db.get_objects_by_search_expression (
                                                          combined_expression,
                                                          "0",
                                                          offset,
                                                          max_objects);

        total_matches = children.size;

        return children;
    }

    public override async Gee.List<MediaObject>? get_children (
                                       uint             offset,
                                       uint             max_count,
                                       Cancellable?     cancellable)
                                       throws GLib.Error {
        if (item_container) {
            uint total_matches;
            return yield this.search (this.expression,
                                      offset,
                                      max_count,
                                      out total_matches,
                                      cancellable);
        }

        var max_objects = max_count;
        if (max_objects == 0) {
            max_objects = -1;
        }

        var children = new ArrayList<MediaObject> ();
        var data = this.media_db.get_object_attribute_by_search_expression (
                                    this.attribute,
                                    this.expression,
                                    offset,
                                    max_objects);
        foreach (var meta_data in data) {
                if (meta_data == null) {
                    continue;
                }

            var new_id = this.id + "," + meta_data;
            var container = new MediaExportQueryContainer (this.media_db,
                                                           new_id,
                                                           meta_data);
            container.parent = this;
            container.parent_ref = this;
            children.add (container);
        }

        return children;
    }
}