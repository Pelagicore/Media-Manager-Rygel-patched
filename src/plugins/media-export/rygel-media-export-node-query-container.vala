/*
 * Copyright (C) 2011 Jens Georg <mail@jensge.org>.
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

internal class Rygel.MediaExport.NodeQueryContainer : QueryContainer {
    private string template;
    private string attribute;

    public NodeQueryContainer (SearchExpression expression,
                               string           id,
                               string           name,
                               string           template,
                               string           attribute) {
        base (expression, id, name);

        this.template = template;
        this.attribute = attribute;

        // base constructor does count_children but it depends on template and
        // attribute; so we have to call it again here after those two have
        // been set.
        try {
            this.child_count = this.count_children ();
        } catch (Error error) {};
    }

    // MediaContainer overrides

    public override async MediaObjects? get_children
                                        (uint         offset,
                                         uint         max_count,
                                         string       sort_criteria,
                                         Cancellable? cancellable)
                                         throws GLib.Error {
        var children = new MediaObjects ();
        var factory = QueryContainerFactory.get_default ();

        if (this.add_all_container ()) {
            var id = this.template.replace (",upnp:album,%s","");
            var container = factory.create_from_description (this.media_db,
                                                             id,
                                                             _("All"));
            container.parent = this;
            children.add (container);
        }

        var data = this.media_db.get_object_attribute_by_search_expression
                                        (this.attribute,
                                         this.expression,
                                         // sort criteria
                                         offset,
                                         max_count);

        foreach (var meta_data in data) {
            var new_id = Uri.escape_string (meta_data, "", true);
            // template contains URL escaped text. This means it might
            // contain '%' chars which will makes sprintf crash
            new_id = this.template.replace ("%s", new_id);
            var container = factory.create_from_description (this.media_db,
                                                             new_id,
                                                             meta_data);
            container.parent = this;
            children.add (container);
        }

        return children;
    }

    // QueryContainer overrides

    protected override int count_children () throws Error {
        // Happens during construction
        if (this.attribute == null || this.expression == null) {
            return 0;
        }

        var data = this.media_db.get_object_attribute_by_search_expression
                                        (this.attribute,
                                         this.expression,
                                         0,
                                         -1);
        if (this.add_all_container ()) {
            return data.size + 1;
        }

        return data.size;
    }

    private bool add_all_container () {
        return this.attribute == "upnp:album" &&
               "upnp:artist" in this.template;
    }
}
